==================================
Guía Técnica de Código para MicrOS
==================================

:Status: Aprobado
:Version: 1.1.0
:Author: Rénich Bon Ćirić & Antigravity
:Date: 2026-09-17
:Language: Español (ES/MX)
:Translations: :doc:`code-guide`

Este documento define el modelo mental arquitectónico, la distribución del código, los puntos de entrada, las canalizaciones de ejecución y los estándares rigurosos de calidad para el sistema operativo MicrOS (µOS), el entorno del lenguaje Macros y la cadena de herramientas de verificación. Todo ingeniero, arquitecto humano o agente autónomo de IA que modifique esta base de código DEBE cumplir con estas normas sin excepción.

Soberanía Computacional y Filosofía Central
===========================================
MicrOS está diseñado para garantizar una absoluta soberanía tecnológica, eliminando el bloqueo por dependencias de librerías externas en tiempo de ejecución y asegurando el determinismo total entre el hardware y el software.

Directivas Filosóficas Principales:
-----------------------------------
* **Substrato Cero-Libc**: La capa de substrato (``src/sys/``) y el kernel (``src/kernel/``) no enlazan librerías externas de C en tiempo de ejecución (``libc``, ``musl`` ni ``glibc``). Toda interacción entre el kernel y el espacio de usuario invoca directamente llamadas al sistema (syscalls) x86_64 de Linux o ensamblador nativo.
* **La Doctrina de Verificación**: Nunca asumas; siempre verifica. Cero suposiciones probabilísticas, atajos asociativos o aserciones engañosas. Toda afirmación sobre mecánicas del compilador, seguridad de memoria o comportamiento del sistema debe verificarse empíricamente contra el código fuente, el estado del sistema de archivos y la ejecución de pruebas.
* **Inmutabilidad Direccionada por Contenido**: Las entidades persistentes, los módulos y los manifiestos de ejecución se direccionan mediante hashes criptográficos BLAKE3 de 256 bits, reemplazando las abstracciones mutables de inodos jerárquicos POSIX.
* **Cero Adulación y Colaboración Directa**: La revisión de ingeniería prioriza la exactitud matemática y la seguridad de memoria sobre el consenso complaciente. La lógica defectuosa, los casos de esquina no manejados y las regresiones arquitectónicas deben señalarse y corregirse sin vacilación.

Arquitectura del Sistema y Modelo Mental
========================================
MicrOS es un sistema operativo nativo para IA, post-POSIX, estructurado sobre un estricto modelo computacional de dos capas que separa la imposición de hardware de la orquestación superior.

Arquitectura de Dos Capas (Substrato y Aplicaciones):
-----------------------------------------------------
1. **Capa 0: Microkernel Soberano y Substrato (Zig)**:
   Un microkernel independiente y capa directa de llamadas al sistema escrito en Zig puro. La Capa 0 administra estructuras de CPU (GDT/IDT), asignación de marcos de página (PMM/VMM), controladores de dispositivos VirtIO (red, almacenamiento), validación de tokens de acceso en el Espacio de Capacidades (CSpace), búferes circulares en memoria compartida estructurada y la máquina virtual de código de bytes con recolector Immix. La Capa 0 jamás enlaza librerías externas y opera con alineación matemática estricta.

2. **Capa 1: Aplicaciones Soberanas y Orquestación (Macros)**:
   El espacio de usuario de alto nivel escrito exclusivamente en el lenguaje Macros (``.mx``, ``.macros``). La Capa 1 abarca la inicialización del sistema (``init.mx``), el intérprete de comandos interactivo (``msh.mx``), el compilador autohospedado y los orquestadores residentes de agentes de IA. Los programas de Capa 1 se ejecutan como actores aislados dentro de fibras cooperativas en espacio de usuario, comunicándose a través de búferes circulares en memoria compartida y capacidades CSpace.

Entornos Duales de Ejecución (UEFI vs Sandbox):
-----------------------------------------------
MicrOS opera en dos entornos distintos y complementarios:

* **Bare-Metal x86_64 UEFI (Producción/Emulación)**:
   El sistema operativo completo arranca desde firmware UEFI (OVMF en QEMU o hardware físico) a través de ``src/boot/uefi_main.zig``. El kernel inicializa el hardware directamente, descubre dispositivos PCI, opera almacenamiento y red VirtIO, monta el Almacenamiento Direccionado por Contenido (CAS), renderiza un lienzo vectorial gráfico de 1280x800 vía UEFI GOP y ejecuta el paquete Génesis dentro de fibras cooperativas.

* **Sandbox de Llamadas Directas en Linux (TDD/CI Rápido)**:
   Para ciclos de desarrollo de sub-segundo, ``src/main.zig`` compila como un ejecutable independiente de Linux (``zig-out/bin/micros-init``) actuando como PID 1 dentro de un sandbox aislado de QEMU o contenedor. Invoca directamente llamadas al sistema de Linux vía ``src/sys/linux.zig`` (cero libc), ejecuta autoverificaciones del substrato, procesa comandos de MicroShell y apaga el sistema limpiamente mediante ACPI S5.

Puntos de Entrada del Sistema y Secuencia de Arranque
=====================================================
Comprender en dónde inicia la ejecución y cómo fluye el control a través de las fronteras es fundamental para navegar por la base de código.

1. Punto de Entrada del Cargador UEFI (src/boot/uefi_main.zig):
   La ejecución arranca en ``pub fn main() uefi.Status`` dentro del cargador Stage 1 UEFI (``boot.efi``):
   * Conecta con la Tabla del Sistema UEFI e inicializa la salida a consola.
   * Descubre el búfer de cuadros de hardware mediante el protocolo UEFI GOP, capturando dirección base, resolución (1280x800) y formato de píxeles en ``FramebufferInfo``.
   * Consulta el mapa de memoria UEFI en un arreglo contiguo de descriptores ``MemoryDescriptor``.
   * Empaqueta límites de memoria física, desplazamientos HHDM y parámetros de video en la estructura verificada ``BootInfo`` (firma mágica ``0x4D494352_4F534249``).
   * Invoca ``uefi.boot_services.exitBootServices`` para finalizar el tiempo de ejecución del firmware UEFI.
   * Salta directamente al punto de entrada del microkernel: ``kernel_main.kmain(&global_boot_info)``.

2. Punto de Entrada del Microkernel (src/kernel/main.zig):
   La ejecución entra al microkernel en ``pub export fn kmain(boot_info: *const BootInfo) callconv(.c) noreturn``:
   * Deshabilita interrupciones de CPU (``cli``) e inicializa el puerto serie UART 16550 para depuración temprana.
   * Valida la firma mágica de ``BootInfo`` e instala la contención de fallas de CPU: Tabla Global de Descriptores (``gdt.init()``) y Tabla de Descriptores de Interrupción (``idt.init()``).
   * Activa el Administrador de Memoria Física (``pmm.init()``) y la paginación virtual de 4 niveles (``vmm.init()``).
   * Escanea el bus PCI en busca de dispositivos VirtIO (VirtIO-Net para paquetes de red, VirtIO-Blk para almacenamiento persistente en bloques).
   * Asigna un montículo de kernel alineado a páginas de 8 MiB mediante ``std.heap.FixedBufferAllocator``.
   * Instancia el Actor Génesis 0 (``actor_mod.Actor.init``) y crea el Espacio de Capacidades raíz (CSpace) con 64 ranuras.
   * Monta el motor de almacenamiento CAS, la caché de bloques y el lienzo vectorial GOP directo.
   * Desempaqueta el paquete Génesis embebido (``genesis.mcb``), extrae ``init.mx``, compila su AST a código de bytes mediante el compilador Stage 0 e inicializa la Máquina Virtual Génesis (``vm_mod.VM``).
   * Enlaza las funciones ABI del microkernel en el ámbito global de la máquina virtual.
   * Inicializa el planificador cooperativo de fibras (``fiber_mod.Scheduler``), engendra el hilo ``vmThread`` y entra al bucle ``sched.run()``.

3. Punto de Entrada de Inicialización y Supervisión (lib/macros/init.mx):
   El primer código de alto nivel en ejecutarse en espacio de usuario corre como Actor Génesis 0/PID 1:
   * Extrae la Aplicación 0 (``msh.mx``) desde el paquete Génesis mediante ``sys_bundle_read("msh.mx")``.
   * Engendra el actor hijo de MicroShell mediante ``sys_actor_spawn_code("msh", msh_src)``.
   * Entra al bucle de supervisión (``supervisor_loop``), consultando periódicamente el estado de los actores hijos (``sys_actor_state``), reviviendo automáticamente actores con fallas y cediendo tiempo de CPU con ``sys_yield()``.

4. Punto de Entrada del Sandbox de Linux (src/main.zig):
   Para pruebas rápidas fuera de la emulación bare-metal, ``pub fn main() !void`` funge como PID 1:
   * Imprime el banner inicial directamente en el descriptor 1 vía ``src/sys/io.zig``.
   * Ejecuta una autoverificación del substrato: compila y evalúa ``boot_check = 20 + 22`` en una instancia limpia de la VM de Macros, asegurando que el resultado sea 42.
   * Instancia ``msh.Shell`` conectado a la entrada estándar (0) y salida estándar (1).
   * Ejecuta comandos iniciales, registra la finalización y apaga el sistema mediante ``sys.process.poweroff()`` (con el valor mágico de reinicio ACPI ``0x4321fedc``).

5. Ejecutores Independientes de Línea de Comandos:
   * ``src/macros_main.zig``: Ejecutor CLI para compilar y correr archivos de script ``.mx`` directamente en el host.
   * ``src/msh_main.zig``: CLI interactivo para iniciar la consola interactiva (REPL) de MicroShell en pruebas locales.

Anatomía del Repositorio: Qué Está en Dónde
===========================================
La base de código se organiza rigurosamente en directorios delimitados por dominio con responsabilidades bien definidas:

Capa del Substrato y Kernel (src/):
-----------------------------------
* ``src/boot/``: Implementación del cargador Stage 1 UEFI (``uefi_main.zig``) y cabeceras de protocolo.
* ``src/kernel/``: Núcleo del microkernel soberano:
   * ``arch/x86_64/``: Conmutación de contexto en ensamblador, GDT, IDT, I/O de puertos, definiciones de paginación.
   * ``mem/``: Asignador de marcos de página física (``pmm.zig``) y Administrador de Memoria Virtual (``vmm.zig``).
   * ``drivers/``: VirtIO-Net 1.0, VirtIO-Blk 1.0, enumeración PCI y teclado PS/2.
   * ``cap/``: Control de acceso basado en capacidades (``capability.zig``, ``cspace.zig``).
   * ``storage/``: Motor de Almacenamiento Direccionado por Contenido (``cas.zig``, ``chunk.zig``, ``block_cache.zig``, ``superblock.zig``).
   * ``ipc/``: Búferes circulares sin cerrojos (``ring.zig``) y canales de eventos fuertemente tipados (``events.zig``).
   * ``compositor/``: Motor de gráficos vectoriales, lienzo de 1280x800, tipografía, puntero de ratón, gestor de ventanas en mosaico BSP.
   * ``net/``: Pila de red integrada en el kernel (cliente DHCP, resolución DNS, máquina de estados TCP, adaptador TLS 1.3).
   * ``ai.zig``: Cliente orquestador de IA residente (streaming HTTP 1.1, generación de prompts, invocación estructurada de herramientas).
   * ``actor.zig`` y ``supervisor.zig``: Ciclo de vida de actores y árboles de supervisión de fallas.
   * ``abi.zig``: Enlaces de funciones ABI y llamadas al sistema expuestas a la máquina virtual Macros.
   * ``main.zig``: Inicialización raíz del microkernel y flujo de ejecución de ``kmain``.
* ``src/sys/``: Librería de llamadas al sistema de Linux independiente de libc (``linux.zig``, ``io.zig``, ``mem.zig``, ``process.zig``).
* ``src/msh/``: Motor de MicroShell (``shell.zig``, ``builtins.zig``) para análisis y tuberías de ejecución de comandos.

Motor de Ejecución del Lenguaje (src/macros/):
----------------------------------------------
La implementación Stage 0 de Macros escrita en Zig independiente:
* ``lexer.zig``: Analiza flujos fuente UTF-8 generando secuencias de tokens tipados.
* ``parser.zig`` y ``ast.zig``: Genera y valida Árboles de Sintaxis Abstracta descendentes recursivos.
* ``compiler.zig`` y ``chunk.zig``: Compila nodos AST en arreglos serializados de instrucciones de código de bytes.
* ``vm.zig``: Intérprete de código de bytes basado en pila de alto rendimiento.
* ``eval.zig``: Intérprete por recorrido de AST empleado durante fases iniciales de bootstrap.
* ``gc.zig`` y ``immix.zig``: Recolector de basura por regiones y marcas Immix (bloques de 32 KiB, mapas de líneas, asignación en huecos).
* ``fiber.zig`` y ``context_switch.s``: Fibras cooperativas en espacio de usuario y conmutación de contexto en ensamblador con preservación de registros.
* ``codegen_x86_64.zig``: Generador independiente de código máquina nativo con protección de páginas W^X.
* ``module.zig`` y ``serializer.zig``: Cargador de módulos CAS (``b3:...`` y ``bundle:...``) y serialización binaria canónica.

Compilador Autohospedado y Aplicaciones (lib/macros/):
------------------------------------------------------
La implementación Stage 1 de Macros escrita íntegramente en Macros puro:
* ``init.mx``: Supervisor del sistema y script de inicialización del Actor 0.
* ``msh.mx``: Implementación soberana de MicroShell escrita en Macros puro.
* ``harness.mx``: Ejecutor autónomo de pruebas y suite de verificación.
* ``ast.mx``, ``lexer.mx``, ``parser.mx``: Frontend del compilador autohospedado.
* ``compiler.mx``, ``compiler_main.mx``: Compilador de código de bytes autohospedado.

Cadena de Herramientas de Verificación (tools/):
------------------------------------------------
Herramientas del host que proporcionan compuertas de calidad automatizadas y verificación diagnóstica:
* ``micros-runner.bash``: Entorno de ejecución desatendido en QEMU dirigido por eventos con detección de centinelas por puerto serie.
* ``src/fb_verify.zig`` (``micros-fb-verify``): Validador visual submilimétrico de varianza cromática en búferes gráficos.
* ``src/lint.zig`` (``micros-lint``): Linter nativo sobre el AST de Zig que hace cumplir los Diez Mandamientos.
* ``src/sym.zig`` (``micros-sym``): Desenredador independiente de tablas de símbolos ELF de 64 bits y traductor de direcciones a líneas.
* ``micros-inspect.bash``: Inspector no interactivo del monitor de QEMU para desensamblado de registros de CPU durante pánicos.
* ``src/telem.zig`` (``micros-telem``): Decodificador binario nativo de telemetría de 64 bytes.
* ``micros-spec-trace.bash``: Auditor de trazabilidad bidireccional entre las 4 capas de especificaciones.
* ``src/virtio_bench.zig`` (``micros-virtio-bench``): Validador de geometría VirtIO split-virtqueue y microbanco de pruebas DMA vía RDTSC.
* ``src/bundle.zig`` (``micros-bundle``): Empaqueta archivos fuente Stage 1 ``.mx`` dentro del paquete binario ``genesis.mcb``.

Cómo se Ensambla Todo: Canalización del Ciclo de Vida
=====================================================
El ciclo de vida de MicrOS enlaza la generación de artefactos en compilación con la ejecución directa en el hardware al arrancar.

Canalización de Ensamblado en Tiempo de Compilación:
----------------------------------------------------
1. **Compilación de Herramientas**: ``make tools`` compila las utilidades nativas de Zig en ``zig-out/bin/``.
2. **Empaquetado del Paquete Génesis**: ``tools/micros-bundle`` lee los scripts fuente Stage 1 desde ``lib/macros/`` (``init.mx``, ``msh.mx``, ``harness.mx``, ``lexer.mx``, ``parser.mx``, ``compiler.mx``, ``compiler_main.mx``) y los serializa en un único archivo binario: ``src/kernel/genesis.mcb``.
3. **Compilación del Microkernel y Cargador**: ``zig build`` compila ``src/boot.zig`` en ``zig-out/bin/boot.efi`` y ``src/kernel.zig`` en ``zig-out/bin/micros-kernel.elf`` (incrustando ``genesis.mcb`` mediante ``@embedFile``).
4. **Compilación del Sandbox**: ``zig build`` compila ``src/main.zig`` en el binario independiente ``zig-out/bin/micros-init``.

Flujo del Ciclo de Vida de Ejecución:
-------------------------------------
La secuencia completa de ejecución desde el encendido en frío hasta la consola interactiva:

.. code-block:: text

   +-------------------------------------------------------------------------+
   | Firmware UEFI (OVMF en QEMU/Hardware Físico)                            |
   +-------------------------------------------------------------------------+
                                      |
                                      v
   +-------------------------------------------------------------------------+
   | Cargador Stage 1: src/boot/uefi_main.zig                                |
   | - Localiza Búfer de Cuadros GOP (1280x800x32)                           |
   | - Captura Descriptores de Memoria en BootInfo (0x4D494352_4F534249)     |
   | - Invoca exitBootServices y salta a kmain                               |
   +-------------------------------------------------------------------------+
                                      |
                                      v
   +-------------------------------------------------------------------------+
   | Raíz del Microkernel: src/kernel/main.zig (kmain)                       |
   | - Inicializa UART serie, GDT, IDT, PMM, VMM (paginación de 4 niveles)    |
   | - Descubre controladores PCI VirtIO-Net y VirtIO-Blk                    |
   | - Monta Almacenamiento CAS y Caché de Bloques                           |
   | - Inicializa CSpace Génesis (64 ranuras) y Lienzo GOP                   |
   | - Desempaqueta genesis.mcb, compila init.mx con compilador Stage 0      |
   | - Enlaza funciones ABI del Microkernel en la VM Génesis                 |
   | - Inicia Planificador de Fibras (fiber_mod.Scheduler.run)               |
   +-------------------------------------------------------------------------+
                                      |
                                      v
   +-------------------------------------------------------------------------+
   | Supervisor del Sistema: lib/macros/init.mx (Actor 0/PID 1 en Macros)    |
   | - Lee msh.mx desde el paquete génesis                                   |
   | - Engendra la Aplicación 0 (msh) vía sys_actor_spawn_code               |
   | - Ejecuta bucle de supervisión monitoreando estados y cediendo CPU      |
   +-------------------------------------------------------------------------+
                                      |
                                      v
   +-------------------------------------------------------------------------+
   | MicroShell y Gestor de Ventanas: lib/macros/msh.mx + kernel/compositor/ |
   | - Renderiza ventanas vectoriales en el lienzo GOP de 1280x800           |
   | - Procesa entrada de teclado PS/2 y eventos del puntero de ratón        |
   | - Orquesta comandos, agentes de IA residentes y módulos CAS             |
   +-------------------------------------------------------------------------+

Los Diez Mandamientos de Calidad de Código
==========================================
Los Diez Mandamientos representan la base innegociable de la artesanía de código en MicrOS. Estas reglas son impuestas de manera determinista mediante el linter nativo de AST (``tools/micros-lint``) y las compuertas automatizadas de integración continua.

.. table:: Resumen de los Diez Mandamientos
   :widths: auto

   +----+--------------------------+-------------------------------------------------------------+
   | No | Mandamiento              | Restricción Obligatoria                                     |
   +====+==========================+=============================================================+
   | 1  | Tamaño Máximo de Archivo | Los archivos no deben exceder 1,000 líneas de código.       |
   +----+--------------------------+-------------------------------------------------------------+
   | 2  | Tamaño Máximo de Función | Las funciones no deben exceder 40 líneas de código.         |
   +----+--------------------------+-------------------------------------------------------------+
   | 3  | Profundidad de Anidación | La profundidad de indentación máxima es de 3 niveles.       |
   +----+--------------------------+-------------------------------------------------------------+
   | 4  | Estilo de Formato        | Cero espacios junto a barras (``palabra/palabra``); zig fmt.|
   +----+--------------------------+-------------------------------------------------------------+
   | 5  | Prohibir Números Mágicos | Constantes tipadas o identificadores en ``UPPER_SNAKE_CASE``|
   +----+--------------------------+-------------------------------------------------------------+
   | 6  | Errores Explícitos       | Prohibido ``catch unreachable`` fuera de bloques de pruebas.|
   +----+--------------------------+-------------------------------------------------------------+
   | 7  | Cero Dependencias Libc   | El substrato jamás debe enlazar ni incluir librerías libc.  |
   +----+--------------------------+-------------------------------------------------------------+
   | 8  | Seguridad de Memoria     | Parámetro ``Allocator`` explícito; sin memoria global oculta|
   +----+--------------------------+-------------------------------------------------------------+
   | 9  | Alineación de Páginas    | Forzar alineación de 4096 bytes en páginas y 512 en sectores|
   +----+--------------------------+-------------------------------------------------------------+
   | 10 | Pruebas Colocalizadas    | Las pruebas deben residir en el mismo módulo que el código. |
   +----+--------------------------+-------------------------------------------------------------+

Mandamiento 1: Tamaño Máximo de Archivo (<= 1,000 Líneas)
---------------------------------------------------------
Ningún archivo fuente debe superar las 1,000 líneas de código. Los archivos monolíticos perjudican el razonamiento local, diluyen los límites del dominio y saturan las ventanas de contexto de los modelos de IA. Cuando un archivo se aproxime a las 800 líneas, debe descomponerse en submódulos de dominio coherentes dentro del mismo directorio de paquete.

Mandamiento 2: Tamaño Máximo de Función (<= 40 Líneas)
------------------------------------------------------
Ninguna función debe superar las 40 líneas de código. Una función de más de 40 líneas vulnera el Principio de Responsabilidad Única y delata múltiples responsabilidades entremezcladas. Descompón la lógica multifásica en funciones auxiliares privadas y breves con nombres de verbos claros.

Mandamiento 3: Profundidad Máxima de Anidación (<= 3 Niveles)
-------------------------------------------------------------
Los bloques anidados en exceso oscurecen el flujo de control y ocultan errores de casos límite. El límite estricto de anidación es de 3 niveles. Aplana la ejecución mediante cláusulas de guarda (guard clauses) y retornos tempranos.

.. code-block:: zig

   // PROHIBIDO: Profundidad de anidación >= 4
   pub fn processPacket(packet: *const Packet) !void {
       if (packet.isValid()) {
           if (packet.hasPayload()) {
               if (packet.header.version == CURRENT_VERSION) {
                   if (packet.isEncrypted()) {
                       try decryptAndRoute(packet);
                   }
               }
           }
       }
   }

   // OBLIGATORIO: Cláusulas de guarda aplanando la anidación a <= 2
   pub fn processPacket(packet: *const Packet) !void {
       if (!packet.isValid()) return error.InvalidPacket;
       if (!packet.hasPayload()) return error.EmptyPayload;
       if (packet.header.version != CURRENT_VERSION) return error.UnsupportedVersion;

       if (packet.isEncrypted()) {
           return decryptAndRoute(packet);
       }
       return routePlaintext(packet);
   }

Mandamiento 4: Estilo de Formato y Uso de Barras Inclinadas
-----------------------------------------------------------
Jamás insertes espacios alrededor de barras inclinadas. Escribe siempre las barras en formato continuo como ``palabra/palabra`` (por ejemplo, ``kernel/userspace``, ``read/write``, ``QEMU/KVM``, ``input/output``), nunca con espacios en blanco separando la barra de las palabras adyacentes. Todo archivo fuente en Zig debe formatearse de forma limpia con ``zig fmt`` antes de confirmarse en el repositorio.

Mandamiento 5: Prohibición de Números Mágicos
---------------------------------------------
Los literales numéricos deben tener un significado semántico definido. Emplea enumeraciones fuertemente tipadas o constantes nombradas en ``UPPER_SNAKE_CASE``.

.. code-block:: zig

   // PROHIBIDO: Literales mágicos sin contexto
   const page = try sys.mem.map(0, 65536, 3, 34, -1, 0);

   // OBLIGATORIO: Constantes tipadas y máscaras de bits
   pub const FIBER_STACK_SIZE: usize = 64 * 1024;
   pub const MMAP_PROT_RW: u32 = sys.linux.PROT_READ | sys.linux.PROT_WRITE;
   pub const MMAP_FLAGS_ANON: u32 = sys.linux.MAP_PRIVATE | sys.linux.MAP_ANONYMOUS;

   const stack_mem = try sys.mem.map(
       0,
       FIBER_STACK_SIZE,
       MMAP_PROT_RW,
       MMAP_FLAGS_ANON,
       -1,
       0,
   );

Mandamiento 6: Propagación Explícita de Errores
-----------------------------------------------
Nunca uses ``catch unreachable`` fuera de aserciones en pruebas unitarias aisladas. Tragar errores o forzar pánicos de ejecución mediante ``unreachable`` en código operativo arruina la tolerancia a fallos. Propaga los errores usando conjuntos de errores de Zig (``!T``) y ``try``, o gestiónalos explícitamente mediante ``catch |err|``.

.. code-block:: zig

   // PROHIBIDO: Ocultar operaciones que pueden fallar
   const handle = openFile(path) catch unreachable;

   // OBLIGATORIO: Propagación explícita o recuperación determinista
   const handle = openFile(path) catch |err| switch (err) {
       error.FileNotFound => return error.MissingResource,
       error.AccessDenied => return error.PermissionDenied,
       else => return err,
   };

Mandamiento 7: Cero Dependencias de Libc
----------------------------------------
La capa de substrato (``src/sys/``) y el kernel (``src/kernel/``) no deben enlazarse ni incluir jamás ``libc`` ni entornos POSIX externos. Toda interacción con el sistema debe ejecutarse a través de envoltorios de llamadas al sistema de Linux independientes (``src/sys/linux.zig``) o ensamblador en línea x86_64.

Mandamiento 8: Seguridad de Memoria y Asignadores Explícitos
------------------------------------------------------------
El Zen de Zig declara: Sin asignaciones ocultas de memoria.
Toda función que asigne memoria dinámica o virtual debe recibir un parámetro explícito ``allocator: std.mem.Allocator``. Las asignaciones en montículos globales están prohibidas. Todo recurso asignado debe liberarse inmediatamente utilizando ``defer`` o ``errdefer``. En las pruebas, verifica la ausencia total de fugas de memoria con ``std.testing.allocator``.

.. code-block:: zig

   pub fn createBuffer(allocator: std.mem.Allocator, capacity: usize) ![]u8 {
       const buffer = try allocator.alloc(u8, capacity);
       errdefer allocator.free(buffer);

       try initializeBuffer(buffer);
       return buffer;
   }

Mandamiento 9: Alineación Matemática de Páginas y Sectores
----------------------------------------------------------
Todo búfer de memoria mapeado mediante ``sys.mem.map``, colas DMA de VirtIO y búferes de cuadros (framebuffer) de hardware debe satisfacer matemáticamente la alineación a límites de página de 4096 bytes. Los bloques de almacenamiento deben garantizar la alineación a sectores de 512 bytes. Los accesos desalineados provocan comportamiento indefinido o excepciones de la CPU.

.. code-block:: zig

   pub const PAGE_SIZE: usize = 4096;
   pub const SECTOR_SIZE: usize = 512;

   pub fn assertPageAligned(addr: usize) !void {
       if (addr % PAGE_SIZE != 0) {
           return error.MisalignedPageBoundary;
       }
   }

   pub fn assertSectorAligned(offset: u64) !void {
       if (offset % SECTOR_SIZE != 0) {
           return error.MisalignedSectorBoundary;
       }
   }

Mandamiento 10: Pruebas Unitarias Colocalizadas
-----------------------------------------------
Las pruebas deben ubicarse en el mismo archivo que el código fuente que validan, utilizando los bloques nativos ``test`` de Zig. La colocalización asegura que las pruebas evolucionen a la par de la implementación y permite la auditoría exhaustiva de funciones privadas e invariantes internas.

.. code-block:: zig

   pub fn addSaturated(a: u32, b: u32) u32 {
       const res = @addWithOverflow(a, b);
       return if (res[1] != 0) std.math.maxInt(u32) else res[0];
   }

   test "addSaturated bounds verification" {
       try std.testing.expectEqual(@as(u32, 42), addSaturated(20, 22));
       try std.testing.expectEqual(std.math.maxInt(u32), addSaturated(std.math.maxInt(u32), 1));
   }

Arquitectura Dirigida por el Dominio y Límites de Módulos
=========================================================
MicrOS establece fronteras estrictas de paquetes. El código debe organizarse en torno a dominios funcionales cohesivos en lugar de agrupaciones utilitarias genéricas.

Regla de Nombres Prohibidos:
----------------------------
Queda estrictamente prohibida la creación de archivos genéricos comodín como ``utils.zig``, ``common.zig`` o ``helpers.zig``. El linter de AST (``tools/micros-lint``) rechaza de inmediato cualquier archivo con dichos nombres. El código debe residir en módulos descriptivos propios de su dominio:

* En lugar de ``utils.zig`` -> ``src/kernel/mem/page_table.zig`` o ``src/kernel/storage/crc32.zig``.
* En lugar de ``common.zig`` -> ``src/sys/constants.zig`` o ``src/macros/chunk.zig``.
* En lugar de ``helpers.zig`` -> ``src/macros/token_stream.zig`` o ``src/kernel/compositor/color.zig``.

Principios de Diseño Arquitectónico:
------------------------------------
* **Regla de Responsabilidad Única de Metz**: Un módulo o estructura posee una única responsabilidad si su propósito puede resumirse en una sola frase concisa sin emplear conjunciones como "y" o "pero".
* **Dilo, No lo Pidas (Tell, Don't Ask)**: Los objetos y estructuras deben comandar comportamientos en lugar de exponer su estado interno para ser manipulado desde el exterior.
* **Ley de Deméter**: Una función solo debe invocar métodos de sus dependencias directas, parámetros de método u objetos instanciados localmente, evitando el encadenamiento excesivo de llamadas (``a.b().c().d()``).
* **Separación entre Comandos y Consultas (CQS)**: Un método debe modificar el estado (devolviendo void) o calcular un resultado (consulta pura, dejando el estado intacto). Nunca combines mutaciones y consultas en la misma operación.

Desarrollo en Zig para el Substrato y Kernel
============================================
La capa de substrato actúa como puente entre el hardware y los entornos de ejecución superiores. En ella aplican invariantes estrictas de alto rendimiento y cero asignaciones en rutas críticas.

Invocación de Syscalls Freestanding:
------------------------------------
El módulo ``src/sys/linux.zig`` implementa envoltorios directos en ensamblador en línea desde ``syscall1`` hasta ``syscall6``. Los valores devueltos deben ser evaluados de inmediato para transformar códigos de error negativos en uniones de error fuertemente tipadas de Zig.

.. code-block:: zig

   pub fn write(fd: i32, buf: []const u8) !usize {
       const rc = linux.syscall3(
           linux.SYS_write,
           @bitCast(@as(isize, fd)),
           @intFromPtr(buf.ptr),
           buf.len,
       );
       if (rc < 0) return linux.toError(rc);
       return @intCast(rc);
   }

Búferes Circulares y Bucles sin Asignación Dinámica:
----------------------------------------------------
Los canales críticos de comunicación (tales como eventos del compositor gráfico, tokens de telemetría y colas VirtIO) deben ejecutarse con cero asignaciones en el montículo. Emplea búferes circulares de capacidad estática con índices atómicos:

.. code-block:: zig

   pub fn RingBuffer(comptime T: type, comptime CAPACITY: usize) type {
       comptime std.debug.assert(std.math.isPowerOfTwo(CAPACITY));
       return struct {
           const Self = @This();
           storage: [CAPACITY]T = undefined,
           head: usize = 0,
           tail: usize = 0,

           pub fn push(self: *Self, item: T) bool {
               const next = (self.head + 1) & (CAPACITY - 1);
               if (next == self.tail) return false; // Lleno
               self.storage[self.head] = item;
               self.head = next;
               return true;
           }

           pub fn pop(self: *Self) ?T {
               if (self.head == self.tail) return null; // Vacío
               const item = self.storage[self.tail];
               self.tail = (self.tail + 1) & (CAPACITY - 1);
               return item;
           }
       };
   }

Estándares del Lenguaje de Programación Macros
==============================================
El lenguaje de programación Macros (``.mx``, ``.macros``) es el lenguaje soberano de aplicaciones y orquestación dentro de MicrOS.

Extensiones de Archivo Canónicas:
---------------------------------
* ``.mx``: Extensión canónica concisa para scripts, módulos y pruebas en Macros.
* ``.macros``: Extensión canónica completa, plenamente soportada por el entorno y el compilador.
* ``.mc``: Extensión histórica mantenida por compatibilidad retrospectiva durante el bootstrap.

Gramática e Idiomas del Lenguaje:
---------------------------------
* Sintaxis orientada a expresiones con límites estrictos de tipos.
* Las variables se declaran y delimitan explícitamente en su ámbito.
* Las funciones se definen mediante ``fn nombre(parámetros) { ... }``.
* La concurrencia de fibras es cooperativa a través de ``yield()``.

.. code-block:: text

   // Implementación canónica en Macros
   fn calculate_checksum(buffer, length) {
       acc = 0;
       i = 0;
       while (i < length) {
           acc = acc + buffer[i];
           i = i + 1;
       }
       return acc;
   }

Invariantes de Memoria del Recolector Immix:
--------------------------------------------
Toda asignación en tiempo de ejecución en Macros opera sobre el recolector de basura por regiones y marcas Immix (``src/macros/gc.zig``):
* **Geometría de Bloques**: Bloques de 32 KiB con 256 líneas de 128 bytes (o 256 bytes según la configuración del entorno).
* **Asignación Rápida en Huecos**: La ruta crítica de asignación ubica memoria en tramos contiguos de líneas reciclables sin fragmentación.
* **Objetos Grandes**: Los objetos mayores a 512 bytes no usan marcas de línea y se asignan directamente en páginas dedicadas de memoria virtual.
* **Trazado Multiraíz**: El recolector traza raíces recorriendo las pilas de ejecución de las fibras, los registros de la máquina virtual y la tabla global de símbolos.

Módulos Direccionados por Contenido (CAS):
------------------------------------------
Los módulos fuente de Macros y los fragmentos binarios precompilados (``.mcb``) se direccionan por su hash BLAKE3 de 256 bits:
* La importación de módulos utiliza el esquema URI ``b3:<digest_hex>`` para dependencias inmutables.
* Los paquetes de arranque del sistema emplean el esquema ``bundle:<nombre>`` para ejecución autocontenida.
* Quedan prohibidas las rutas mutables jerárquicas del sistema de archivos en el runtime del kernel.

Estándares de Scripting en Bash
===============================
Los scripts de verificación del host, ejecutores de pruebas y herramientas auxiliares en Bash deben cumplir con estándares rigurosos de programación defensiva.

Invariantes Obligatorias para Scripts:
--------------------------------------
#. **Extensión de Archivo**: Debe utilizarse exclusivamente ``.bash`` (por ejemplo, ``tools/micros-runner.bash``). Queda prohibida la extensión ``.sh``.
#. **Shebang**: Todo script debe comenzar con ``#!/usr/bin/bash``.
#. **Encabezado Estricto**: Inmediatamente tras el shebang, debe declararse:

   .. code-block:: bash

      set -euo pipefail
      IFS=$'\n\t'

#. **Ámbito de Variables**: Toda variable dentro de una función debe declararse con ``local``.
#. **Condicionales**: Emplea corchetes dobles ``[[ ... ]]`` para pruebas lógicas en lugar de ``[ ... ]``.
#. **Sustitución de Comandos**: Utiliza la sintaxis ``$(comando)`` en lugar de comillas invertidas.
#. **Análisis Estático**: Todo script debe pasar ``shellcheck`` con cero advertencias y cero errores.

Cadena de Herramientas de Verificación y Protocolo Pre-Commit
=============================================================
MicrOS cuenta con una suite completa de herramientas en ``tools/`` para hacer cumplir las compuertas de calidad de manera determinista.

Catálogo de Herramientas del Substrato:
---------------------------------------
* **micros-runner**: Ejecutor desatendido de QEMU dirigido por eventos para pruebas en UEFI y en el sandbox de Linux.
* **micros-fb-verify**: Validador visual submilimétrico de varianza de color y regresión cromática de búferes gráficos.
* **micros-lint**: Motor nativo de análisis estático sobre el AST de Zig que impone los Diez Mandamientos.
* **micros-sym**: Desenredador autónomo de tablas de símbolos ELF de 64 bits y traductor de direcciones a líneas.
* **micros-inspect**: Inspector no interactivo del socket del monitor de QEMU para desensamblado de registros de CPU durante pánicos.
* **micros-telem**: Decodificador nativo de tramas binarias de telemetría de 64 bytes y analizador de fallas.
* **micros-spec-trace**: Auditor de trazabilidad bidireccional entre especificaciones de negocio, funcionales, técnicas y tareas de ruta.
* **micros-virtio-bench**: Validador geométrico de colas divididas VirtIO 1.0 y microbanco de pruebas RDTSC para transferencias DMA.
* **micros-bundle**: Empaquetador binario del paquete génesis que serializa archivos Stage 1 de Macros en ``genesis.mcb``.

Lista de Verificación Obligatoria Pre-Commit:
---------------------------------------------
Antes de registrar cualquier confirmación en el repositorio, ejecuta la siguiente secuencia de validación:

#. Compilar todas las herramientas:

   .. code-block:: bash

      make tools

#. Ejecutar el linter estático y ShellCheck:

   .. code-block:: bash

      make lint

#. Verificar el formateo de código:

   .. code-block:: bash

      make fmt-check

#. Comprobar la trazabilidad de especificaciones:

   .. code-block:: bash

      make spec-trace

#. Ejecutar la suite de pruebas unitarias:

   .. code-block:: bash

      zig build test
      make -C tools test

#. Ejecutar las pruebas de integración en UEFI y sandbox:

   .. code-block:: bash

      make test-sandbox
      make test-uefi

Estándares de Git e Higiene de Confirmaciones
=============================================
Los mensajes de confirmación deben apegarse estrictamente a la especificación de Conventional Commits:

* Estructura: ``tipo(ámbito): descripción concisa en tiempo presente``
* Tipos válidos: ``feat``, ``fix``, ``docs``, ``style``, ``refactor``, ``perf``, ``test``, ``chore``.
* Ejemplo: ``feat(gc): consolidate Immix mark-region collector with multi-root tracing``
* Las confirmaciones deben incorporar firmas de autoría humana y de agentes (``git commit -s``).
* Queda estrictamente prohibido incluir credenciales, llaves de API o endpoints privados en el repositorio.
