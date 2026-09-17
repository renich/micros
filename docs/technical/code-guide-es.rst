==================================
Guía Técnica de Código para MicrOS
==================================

:Status: Aprobado
:Version: 1.0.0
:Author: Rénich Bon Ćirić & Antigravity
:Date: 2026-09-17
:Language: Español (ES/MX)
:Translations: :doc:`code-guide`

Este documento define los estándares autorizados de ingeniería, arquitectura y calidad de código para el sistema operativo MicrOS (µOS), el substrato del lenguaje de programación Macros y la cadena de herramientas de verificación en el host. Todo ingeniero, arquitecto humano o agente autónomo de IA que interactúe con esta base de código DEBE cumplir con estas normas sin excepción.

Soberanía Computacional y Filosofía Central
===========================================
MicrOS está diseñado para garantizar una absoluta soberanía tecnológica, eliminando el bloqueo por dependencias de librerías externas en tiempo de ejecución y asegurando el determinismo total entre el hardware y el software.

Directivas Filosóficas Principales:
-----------------------------------
* **Substrato Cero-Libc**: La capa de substrato (``src/sys/``) y el kernel (``src/kernel/``) no enlazan librerías externas de C en tiempo de ejecución (``libc``, ``musl`` ni ``glibc``). Toda interacción entre el kernel y el espacio de usuario invoca directamente llamadas al sistema (syscalls) x86_64 de Linux o ensamblador nativo.
* **La Doctrina de Verificación**: Nunca asumas; siempre verifica. Cero suposiciones probabilísticas, atajos asociativos o aserciones engañosas. Toda afirmación sobre mecánicas del compilador, seguridad de memoria o comportamiento del sistema debe verificarse empíricamente contra el código fuente, el estado del sistema de archivos y la ejecución de pruebas.
* **Inmutabilidad Direccionada por Contenido**: Las entidades persistentes, los módulos y los manifiestos de ejecución se direccionan mediante hashes criptográficos BLAKE3 de 256 bits, reemplazando las abstracciones mutables de inodos jerárquicos POSIX.
* **Cero Adulación y Colaboración Directa**: La revisión de ingeniería prioriza la exactitud matemática y la seguridad de memoria sobre el consenso complaciente. La lógica defectuosa, los casos de esquina no manejados y las regresiones arquitectónicas deben señalarse y corregirse sin vacilación.

Los Diez Mandamientos de Calidad de Código
==========================================
Los Diez Mandamientos representan la base innegociable de la artesanía de código en MicrOS. Estas reglas son impuestas de manera determinista mediante el linter nativo de AST (``tools/micros-lint``) y las compuertas automatizadas de integración continua.

.. table:: Resumen de los Diez Mandamientos
   :widths: auto

   +----+--------------------------+-------------------------------------------------------------+
   | #  | Mandamiento              | Restricción Obligatoria                                     |
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

* En lugar de ``utils.zig`` -> ``src/kernel/memory/page_table.zig`` o ``src/kernel/storage/crc32.zig``.
* En lugar de ``common.zig`` -> ``src/sys/constants.zig`` o ``src/macros/types.zig``.
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
