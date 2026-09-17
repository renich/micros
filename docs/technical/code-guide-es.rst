================================================
Guía para Comprender la Base de Código de MicrOS
================================================

:Status: Aprobado
:Version: 2.0.0
:Author: Rénich Bon Ćirić & Antigravity
:Date: 2026-09-17
:Language: Español (ES/MX)
:Translations: :doc:`code-guide`

Este documento es la guía arquitectónica y estructural exhaustiva para comprender la base de código de MicrOS (µOS). Proporciona a los arquitectos de sistemas humanos y a los agentes autónomos de IA el modelo mental fundamental, los puntos de entrada, las interacciones entre subsistemas y los mapas de navegación necesarios para explorar, comprender y extender el sistema.

Filosofía Arquitectónica Central y Modelo Mental
================================================
MicrOS es un sistema operativo independiente, computacionalmente soberano y post-POSIX, construido desde el silicio en Zig puro y el lenguaje de programación Macros. Su misión fundamental es erradicar medio siglo de sobrecarga acumulada en los sistemas operativos tradicionales y proporcionar un substrato determinista y seguro diseñado específicamente para la programación en pareja humano-IA.

Los Dos Mundos Computacionales:
-------------------------------
La base de código está dividida limpiamente en dos capas colaborativas:

1. **Capa 0: Substrato y Microkernel Soberano (Zig)**:
   Ubicada en ``src/sys/`` y ``src/kernel/``, la Capa 0 está escrita en Zig independiente sin librerías estándar de C externas (cero libc). Interactúa directamente con las estructuras de hardware x86_64 y los dispositivos. La Capa 0 gestiona la Tabla Global de Descriptores (GDT), la Tabla de Descriptores de Interrupción (IDT), los marcos de página física (PMM), la paginación virtual de 4 niveles (VMM), los controladores de red y almacenamiento VirtIO, los tokens de seguridad del Espacio de Capacidades (CSpace), los búferes circulares en memoria compartida sin bloqueos y la máquina virtual de código de bytes con recolector Immix.

2. **Capa 1: Aplicaciones Soberanas en Espacio de Usuario (Macros)**:
   Ubicada en ``lib/macros/`` y escrita en el lenguaje Macros (``.mx``, ``.macros``), la Capa 1 define la personalidad del sistema. Contiene el supervisor del sistema (``init.mx``), el intérprete interactivo MicroShell (``msh.mx``), los entornos de ejecución autónomos y la canalización del compilador autohospedado. Los programas de Capa 1 se ejecutan como actores aislados planificados sobre fibras cooperativas en espacio de usuario, comunicándose mediante búferes circulares tipados y tokens de capacidad CSpace explícitos.

Eliminación del Lastre Histórico de POSIX:
------------------------------------------
Para alcanzar determinismo matemático y contención estricta de fallas, MicrOS descarta explícitamente cuatro abstracciones históricas de POSIX:

* **Sin Autoridad Ambiental**: No existe el superusuario (``root``) ni permisos ambientales globales. Ningún proceso puede acceder a un recurso por el mero hecho de existir; toda operación exige presentar un token de capacidad validado desde el CSpace local del actor.
* **Sin Sistemas de Archivos Jerárquicos Mutables**: Los árboles de directorios jerárquicos y los inodos mutables son sustituidos por el Almacenamiento Direccionado por Contenido (CAS) mediante hashes criptográficos BLAKE3 de 256 bits. Los módulos, fragmentos de código de bytes y manifiestos de estado son objetos inmutables identificados por su resumen criptográfico.
* **Sin Tuberías ASCII sin Tipar**: La comunicación inter-procesos no serializa datos en flujos ciegos de bytes. Los procesos se comunican a través de búferes circulares estructurados en memoria compartida con esquemas binarios estrictos.
* **Sin Dependencias de Runtime de C**: Ni glibc ni musl se enlazan en el substrato. Toda interacción de bajo nivel se produce mediante ensamblador en línea o envoltorios directos de llamadas al sistema de Linux.

Entornos Duales de Ejecución (UEFI vs Sandbox):
-----------------------------------------------
La base de código está diseñada para compilarse y ejecutarse en dos entornos complementarios:

* **Bare-Metal x86_64 UEFI (Entorno de Producción/Emulación)**:
   El entorno operativo principal. Arranca mediante firmware UEFI (OVMF en QEMU o hardware físico) a través de ``src/boot/uefi_main.zig``. El microkernel inicializa directamente las tablas de CPU, la paginación, dispositivos PCI, almacenamiento y red VirtIO, monta el almacenamiento CAS, inicializa el lienzo vectorial GOP de 1280x800 con doble búfer y ejecuta el paquete Génesis dentro de fibras cooperativas.

* **Sandbox de Llamadas Directas en Linux (Entorno de TDD/CI Rápido)**:
   Para desarrollo ágil e integración continua, ``src/main.zig`` compila como un binario independiente (``zig-out/bin/micros-init``) que actúa como PID 1 dentro de un sandbox aislado de Linux en QEMU o contenedor. Se comunica con el kernel Linux mediante llamadas directas en ``src/sys/linux.zig``, ejecuta autoverificaciones, procesa comandos de MicroShell y apaga el sistema mediante ACPI S5 en milisegundos.

Puntos de Entrada del Sistema y Secuencia de Arranque
=====================================================
Rastrear el flujo de control desde el encendido del hardware hasta la consola interactiva permite entender el ensamblado de cada subsistema.

1. Cargador Bare-Metal UEFI (src/boot/uefi_main.zig):
-----------------------------------------------------
El control inicia en ``pub fn main() uefi.Status`` dentro de ``boot.efi``:

* **Handshake con Firmware**: Conecta con la Tabla del Sistema UEFI e inicializa la salida por consola serie.
* **Descubrimiento de Pantalla**: Localiza el protocolo UEFI Graphics Output Protocol (GOP), extrayendo dirección base, resolución (1280x800), paso de línea y formato de píxeles en ``FramebufferInfo``.
* **Lectura del Mapa de Memoria**: Consulta el mapa de memoria de UEFI en un búfer contiguo de descriptores ``MemoryDescriptor``, clasificando RAM utilizable, datos del cargador y memoria reservada.
* **Empaquetado de BootInfo**: Estructura los límites de memoria física, desplazamientos HHDM y parámetros gráficos en la estructura validada ``BootInfo`` con firma mágica ``0x4D494352_4F534249``.
* **Salida de Servicios de Arranque**: Invoca ``uefi.boot_services.exitBootServices``, desconectando los controladores de UEFI.
* **Transición al Microkernel**: Salta directamente al punto de entrada del microkernel: ``kernel_main.kmain(&global_boot_info)``.

2. Raíz del Microkernel Soberano (src/kernel/main.zig):
-------------------------------------------------------
La ejecución entra al microkernel en ``pub export fn kmain(boot_info: *const BootInfo) callconv(.c) noreturn``:

* **Contención de Fallas de CPU**: Deshabilita interrupciones (``cli``), inicializa el puerto serie UART 16550 y carga la Tabla Global de Descriptores (``gdt.init()``) y la Tabla de Descriptores de Interrupción (``idt.init()``).
* **Inicialización de Memoria**: Configura el Administrador de Memoria Física (``pmm.init()``) y las tablas de paginación virtual de 4 niveles (``vmm.init()``).
* **Detección de Dispositivos**: Escanea el bus PCI y enlaza los controladores VirtIO-Net 1.0 (red) y VirtIO-Blk 1.0 (almacenamiento).
* **Montículo del Kernel y CSpace**: Reserva un montículo alineado a páginas de 8 MiB, instancia el Actor Génesis 0 y crea el CSpace raíz con 64 ranuras.
* **Montaje de CAS y Gráficos**: Monta el motor de almacenamiento direccionado por contenido, la caché de bloques y el lienzo gráfico vectorial GOP de 1280x800.
* **Desempaquetado del Paquete Génesis**: Accede al archivo binario embebido ``genesis.mcb``, extrae ``init.mx``, lo compila a código de bytes con el compilador Stage 0 e inicializa la Máquina Virtual Génesis.
* **Registro de ABI**: Inyecta las funciones ABI del microkernel (``sys_actor_spawn_code``, ``sys_bundle_read``, ``sys_yield``, ``sys_actor_state``) en el ámbito global de la máquina virtual.
* **Inicio del Planificador de Fibras**: Inicializa el planificador cooperativo en espacio de usuario (``fiber_mod.Scheduler``), engendra el hilo ``vmThread`` y arranca el bucle ``sched.run()``.

3. Supervisor de Inicialización de Alto Nivel (lib/macros/init.mx):
-------------------------------------------------------------------
El primer código en espacio de usuario que corre dentro de la VM Génesis actúa como Actor 0 (PID 1):

* **Despliegue de App 0**: Lee ``msh.mx`` desde el paquete Génesis mediante ``sys_bundle_read("msh.mx")``.
* **Engendrado de Actor**: Genera el actor hijo de MicroShell mediante ``sys_actor_spawn_code("msh", msh_src)``.
* **Bucle de Supervisión**: Entra en ``supervisor_loop``, consultando el estado de los actores hijos (``sys_actor_state``), reviviendo automáticamente aquellos que presenten fallas y cediendo CPU con ``sys_yield()``.

4. Sandbox de Llamadas Directas en Linux (src/main.zig):
--------------------------------------------------------
Cuando se ejecuta en modo sandbox, el control arranca en ``pub fn main() !void``:

* **Diagnóstico por Syscalls Directas**: Emite mensajes de inicio directamente al descriptor 1 mediante ``src/sys/io.zig``.
* **Autoverificación del Substrato**: Ejecuta una prueba automática compilando y evaluando ``boot_check = 20 + 22`` en una VM limpia de Macros, verificando que el resultado sea 42.
* **Lanzamiento de MicroShell**: Instancia ``msh.Shell`` conectado a la entrada y salida estándar.
* **Apagado Limpio**: Llama a ``sys.process.poweroff()`` para apagar la máquina mediante la constante mágica de reinicio ACPI (``0x4321fedc``).

5. Ejecutores Independientes en el Host:
----------------------------------------
* ``src/macros_main.zig``: Utilidad de línea de comandos para compilar y ejecutar archivos ``.mx`` directamente en el host.
* ``src/msh_main.zig``: Interfaz interactiva de consola para probar el REPL de MicroShell en local.

Anatomía del Repositorio: Qué Está en Dónde
===========================================
El repositorio está dividido estrictamente en capas funcionales independientes:

Substrato y Microkernel (src/):
-------------------------------
El núcleo del sistema escrito en Zig independiente:

* ``src/boot/``: Implementación del cargador Stage 1 UEFI (``uefi_main.zig``) y protocolos de memoria.
* ``src/kernel/``: Implementación central del microkernel soberano:
   * ``arch/x86_64/``: Conmutación de contexto en ensamblador, GDT, IDT, puertos de E/S, registros de control.
   * ``mem/``: Asignador de marcos de página física (``pmm.zig``) y Administrador de Memoria Virtual (``vmm.zig``).
   * ``drivers/``: VirtIO-Net 1.0, VirtIO-Blk 1.0, escaneo de bus PCI y teclado PS/2.
   * ``cap/``: Motor de control de accesos basado en capacidades (``capability.zig``, ``cspace.zig``).
   * ``storage/``: Motor de almacenamiento direccionado por contenido (``cas.zig``, ``chunk.zig``, ``block_cache.zig``, ``superblock.zig``).
   * ``ipc/``: Búferes circulares sin cerrojos (``ring.zig``) y canales de eventos tipados (``events.zig``).
   * ``compositor/``: Motor de gráficos vectoriales, lienzo de 1280x800, renderizado de fuentes, cursor de ratón y gestor de ventanas BSP en mosaico.
   * ``net/``: Pila de red integrada en el kernel (cliente DHCP, resolución DNS, máquina de estados TCP, adaptador TLS 1.3).
   * ``ai.zig``: Subsistema de IA residente para sesiones de streaming HTTP 1.1 con Gemini u otros proveedores.
   * ``actor.zig`` y ``supervisor.zig``: Gestión del ciclo de vida de actores y jerarquías de supervisión.
   * ``abi.zig``: Enlaces de funciones ABI y llamadas al sistema expuestas a la máquina virtual Macros.
   * ``main.zig``: Punto de entrada raíz del microkernel (``kmain``).
* ``src/sys/``: Librería de llamadas al sistema de Linux independiente de libc (``linux.zig``, ``io.zig``, ``mem.zig``, ``process.zig``).
* ``src/msh/``: Implementación de MicroShell para el host (``shell.zig``, ``builtins.zig``).

Motor del Lenguaje y Tiempo de Ejecución (src/macros/):
-------------------------------------------------------
La implementación Stage 0 de Macros en Zig:

* ``lexer.zig``: Analiza flujos fuente UTF-8 generando secuencias de tokens fuertemente tipados.
* ``parser.zig`` y ``ast.zig``: Genera y valida Árboles de Sintaxis Abstracta descendentes recursivos.
* ``compiler.zig`` y ``chunk.zig``: Compila nodos AST en fragmentos serializados de código de bytes.
* ``vm.zig``: Máquina virtual basada en pila que ejecuta instrucciones de código de bytes.
* ``eval.zig``: Intérprete por recorrido de AST utilizado durante etapas iniciales de arranque.
* ``gc.zig`` y ``immix.zig``: Recolector de basura Immix (bloques de 32 KiB, mapas de líneas, reciclaje de huecos).
* ``fiber.zig`` y ``context_switch.s``: Fibras cooperativas en espacio de usuario y conmutación en ensamblador.
* ``codegen_x86_64.zig``: Generador de código máquina nativo con protección de páginas W^X.
* ``module.zig`` y ``serializer.zig``: Resolutor de módulos CAS (``b3:...`` y ``bundle:...``) y serialización canónica.

Aplicaciones Autohospedadas (lib/macros/):
------------------------------------------
La implementación Stage 1 de Macros escrita íntegramente en Macros puro:

* ``init.mx``: Supervisor del sistema y script raíz de inicialización del Actor 0.
* ``msh.mx``: Implementación de MicroShell escrita en Macros puro.
* ``harness.mx``: Ejecutor autónomo de pruebas y suite de verificación.
* ``ast.mx``, ``lexer.mx``, ``parser.mx``: Frontend del compilador autohospedado.
* ``compiler.mx``, ``compiler_main.mx``: Compilador de código de bytes autohospedado.

Cadena de Herramientas de Verificación y Compilación (tools/):
--------------------------------------------------------------
Utilidades del host que aseguran la corrección y calidad del sistema:

* ``micros-runner.bash``: Entorno de pruebas desatendido en QEMU dirigido por eventos y centinelas serie.
* ``src/fb_verify.zig`` (``micros-fb-verify``): Validador visual submilimétrico de búferes gráficos.
* ``src/lint.zig`` (``micros-lint``): Linter nativo sobre el AST de Zig que evalúa métricas de calidad.
* ``src/sym.zig`` (``micros-sym``): Desenredador independiente de símbolos ELF y traductor de direcciones a líneas.
* ``micros-inspect.bash``: Inspector del monitor de QEMU para desensamblado de registros de CPU durante pánicos.
* ``src/telem.zig`` (``micros-telem``): Decodificador nativo de telemetría binaria de 64 bytes.
* ``micros-spec-trace.bash``: Auditor de trazabilidad bidireccional entre las cuatro capas de especificaciones.
* ``src/virtio_bench.zig`` (``micros-virtio-bench``): Validador geométrico de VirtIO y banco de pruebas DMA vía RDTSC.
* ``src/bundle.zig`` (``micros-bundle``): Empaquetador de archivos fuente ``.mx`` en el archivo binario ``genesis.mcb``.

Análisis de Subsistemas: Interacción entre Componentes
======================================================
Para modificar o depurar MicrOS con eficacia, es indispensable entender cómo se coordinan el substrato y el espacio de usuario.

El Puente ABI entre Zig y Macros:
---------------------------------
El microkernel expone las capacidades del hardware a Macros mediante ``src/kernel/abi.zig``. La VM mantiene una tabla de entorno global donde se registran funciones nativas de Zig:

.. code-block:: zig

   // Registro de ABI en src/kernel/abi.zig
   pub fn registerBuiltins(vm: *vm_mod.VM) !void {
       try vm.registerNative("sys_actor_spawn_code", nativeActorSpawnCode);
       try vm.registerNative("sys_bundle_read", nativeBundleRead);
       try vm.registerNative("sys_yield", nativeYield);
       try vm.registerNative("sys_actor_state", nativeActorState);
       try vm.registerNative("sys_wm_create_window", nativeWmCreateWindow);
   }

Cuando un script en Macros ejecuta ``sys_bundle_read("msh.mx")``, la VM pausa el código de bytes, extrae los argumentos de la pila de operandos, invoca la función nativa en Zig y devuelve el resultado ``eval.Value`` a la pila sin fugas de memoria.

Arquitectura de Memoria y Recolector Immix:
-------------------------------------------
La administración de memoria se organiza en dos niveles complementarios:

1. **Nivel de Páginas de Hardware (PMM/VMM)**:
   El administrador de memoria física (``pmm.zig``) gestiona marcos de 4096 bytes mediante un mapa de bits. El administrador de memoria virtual (``vmm.zig``) construye tablas de paginación de 4 niveles que mapean la RAM física al mapa directo superior (HHDM).
2. **Nivel de Objetos (Recolector Immix)**:
   El entorno de Macros utiliza un recolector por regiones y marcas Immix (``src/macros/gc.zig``). Reserva memoria en bloques de 32 KiB subdivididos en 256 líneas de 128 bytes. Los objetos pequeños se asignan rápidamente mediante bump pointers en huecos libres de líneas contiguas, eliminando la fragmentación externa. Los objetos grandes (> 512 bytes) se mapean directamente a páginas virtuales dedicadas.

Fibras Cooperativas en Espacio de Usuario:
------------------------------------------
MicrOS descarta los hilos preemptivos del kernel para la orquestación de aplicaciones, utilizando fibras ligeras en espacio de usuario (``src/macros/fiber.zig``):

* **Estructura de la Fibra**: Cada fibra dispone de una pila aislada de 64 KiB alineada a páginas.
* **Conmutación de Contexto**: La rutina en ensamblador en ``src/macros/context_switch.s`` guarda los registros callee-saved (``rbx``, ``rbp``, ``r12``, ``r13``, ``r14``, ``r15``) en la pila actual, conmuta el puntero de pila (``rsp``) y restaura los registros de la fibra destino.
* **Planificación no Preemptiva**: Las fibras ceden voluntariamente el control mediante ``yield()`` o al esperar eventos de E/S, eliminando el coste de sincronización en el kernel.

Substrato de Almacenamiento Direccionado por Contenido (CAS):
-------------------------------------------------------------
MicrOS almacena los datos persistentes mediante direccionamiento por contenido (``src/kernel/storage/cas.zig``):

* **Direccionamiento BLAKE3**: Cada fragmento de datos se identifica por su hash BLAKE3 de 256 bits (``b3:<hex>``).
* **Controlador VirtIO-Blk**: Las transferencias a disco operan en sectores de 512 bytes respaldados por una caché LRU de bloques.
* **Manifiestos del Sistema**: En lugar de tablas mutables de archivos, el estado del sistema se representa mediante árboles de hashes criptográficos cuyos superbloques avanzan de manera monótona tras confirmarse la escritura.

Seguridad Basada en Capacidades (CSpace):
-----------------------------------------
Cada actor en MicrOS se ejecuta dentro de un entorno aislado gobernado por su Espacio de Capacidades (``src/kernel/cap/cspace.zig``):

* **Tokens de Capacidad**: Representan credenciales no falsificables que otorgan derechos específicos (lectura, escritura, engendrado, envío, mapeo) sobre objetos del kernel (pantalla, búfer circular, almacenamiento, sockets de red).
* **Cero Autoridad Ambiental**: Si un actor intenta escribir en pantalla o transmitir un mensaje sin presentar una ranura válida de capacidad, el microkernel aborta la ejecución del actor de forma inmediata.

Compositor Gráfico Vectorial y Gestor de Ventanas:
--------------------------------------------------
La interfaz gráfica (``src/kernel/compositor.zig``) dibuja directamente sobre el búfer GOP de UEFI:

* **Doble Búfer**: Renderiza sobre un búfer trasero de 1280x800x32 y transfiere únicamente las regiones modificadas (dirty rects) a la pantalla frontal, eliminando el parpadeo.
* **Gestor de Ventanas BSP en Mosaico**: Las ventanas se estructuran en un árbol de partición binaria del espacio (BSP), organizando automáticamente las superficies visibles.
* **Distribución de Eventos**: Los paquetes del teclado PS/2 y los movimientos del ratón se entregan a la superficie activa a través de su cola de eventos en memoria compartida.

El Paquete Génesis y la Canalización de Autohospedaje
=====================================================
MicrOS está diseñado para compilarse a sí mismo, asegurando independencia tecnológica frente a herramientas externas.

Flujo de Empaquetado en Compilación:
------------------------------------
1. **Compilación de Herramientas**: Las utilidades del host (incluyendo ``micros-bundle``) se compilan con ``make tools``.
2. **Serialización del Paquete**: ``tools/micros-bundle`` lee los archivos fuente Stage 1 desde ``lib/macros/`` (``init.mx``, ``msh.mx``, ``harness.mx``, ``lexer.mx``, ``parser.mx``, ``compiler.mx``, ``compiler_main.mx``) y los serializa en ``src/kernel/genesis.mcb``.
3. **Incrustación en el Kernel**: El código fuente del microkernel (``src/kernel/main.zig``) incrusta este archivo binario mediante ``@embedFile("genesis.mcb")``. Al arrancar en hardware real, todo el código de usuario esencial ya se encuentra en memoria sin requerir drivers de disco.

Verificación de Punto Fijo de Autohospedaje:
--------------------------------------------
La canalización de autohospedaje opera en tres fases:

* **Stage 0**: El motor en Zig en ``src/macros/`` evalúa los scripts del compilador Stage 1.
* **Stage 1**: El compilador en Macros puro en ``lib/macros/compiler.mx`` procesa código fuente de Macros y genera código de bytes.
* **Stage 2**: El compilador generado se ejecuta para compilarse a sí mismo de nuevo, verificando que los hashes BLAKE3 resultantes sean exactamente idénticos (punto fijo), demostrando el determinismo del compilador.

Guía para Desarrolladores: Navegación y Extensión
=================================================
Al realizar contribuciones en MicrOS, consulta los siguientes flujos de trabajo habituales:

Cómo Agregar una Nueva Syscall o Capacidad al Microkernel:
----------------------------------------------------------
#. **Definir el Prototipo en la ABI**: En ``src/kernel/abi.zig``, implementa el manejador nativo en Zig (por ejemplo, ``nativeMiCaracteristica``), extrayendo los argumentos de ``args: []eval.Value``.
#. **Registrar en Builtins**: Registra la función dentro de ``registerBuiltins`` en ``src/kernel/abi.zig``:
   ``try vm.registerNative("sys_mi_caracteristica", nativeMiCaracteristica);``
#. **Implementar la Lógica en el Kernel**: Si accede a un controlador o subsistema de memoria, invoca el módulo correspondiente en ``src/kernel/``, validando la capacidad CSpace del actor solicitante.
#. **Exponer al Espacio de Usuario**: Utiliza la nueva primitiva en ``lib/macros/init.mx`` o ``lib/macros/msh.mx``.

Cómo Agregar una Nueva Primitiva u Opcode a Macros:
---------------------------------------------------
#. **Definición del Opcode**: Añade el nuevo tag de opcode al enum ``OpCode`` en ``src/macros/chunk.zig``.
#. **Escaneo y Análisis Sintáctico**: Modifica ``src/macros/lexer.zig`` (si introduces palabras clave) y ``src/macros/parser.zig`` para producir el nodo AST.
#. **Emisión en el Compilador**: En ``src/macros/compiler.zig``, emite la nueva instrucción de código de bytes y sus operandos en el chunk activo.
#. **Ejecución en la VM**: En ``src/macros/vm.zig``, agrega una rama en el bucle de ejecución para procesar el opcode.
#. **Sincronización en Autohospedaje**: Refleja los cambios sintácticos y de generación en ``lib/macros/lexer.mx``, ``parser.mx`` y ``compiler.mx``.

Cómo Depurar un Cuelgue o Pánico del Kernel:
--------------------------------------------
#. **Captura de Consola Serie**: Revisa los registros serie generados por el kernel (capturados automáticamente con ``tools/micros-runner.bash --serial-log build/serial.log``).
#. **Resolución de Símbolos**: Procesa las direcciones hexadecimales con ``./tools/micros-sym <direccion>`` para obtener nombres de función y líneas.
#. **Inspección de Registros**: Si QEMU se congela, ejecuta ``./tools/micros-inspect`` para conectar al monitor y obtener los registros de CPU (RAX, CR3, RIP) y el desensamblado.
#. **Decodificación de Telemetría**: Si los canales de telemetría están activos, examina las tramas con ``./tools/micros-telem -f /tmp/telemetry.bin``.

Ejecución de la Suite de Verificación:
--------------------------------------
Antes de enviar modificaciones, ejecuta la secuencia completa de validación:

.. code-block:: bash

   # 1. Compilar herramientas de verificación
   make tools

   # 2. Ejecutar analizador estático y ShellCheck
   make lint

   # 3. Verificar formateo del código fuente
   make fmt-check

   # 4. Auditar trazabilidad de especificaciones
   make spec-trace

   # 5. Ejecutar suite de pruebas unitarias
   zig build test

   # 6. Ejecutar arranque desatendido bare-metal en QEMU
   make test-uefi

   # 7. Ejecutar prueba del sandbox de llamadas directas
   make test-sandbox
