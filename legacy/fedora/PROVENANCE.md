# Procedencia: obra de terceros

**Este directorio no es obra de este proyecto.**

Es el stack original para **Fedora** (Intel NUC 15 Pro+, AORUS RTX 5090),
autoría de:

- [`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu) — diseño
  original del stack, los servicios `aorus-egpu-*`, los instaladores y la
  metodología de captura de evidencia.
- [`iecxiv/aorus-5060-egpu`](https://github.com/iecxiv/aorus-5060-egpu) —
  adaptación a la RTX 5060 Ti (device IDs, umbrales de BAR1, etiquetas).

Licencia **GPL-2.0**, igual que el resto del repositorio.

## Por qué sigue aquí

Como **referencia**, no como código vivo:

- Documenta el enfoque que funcionaba en Fedora, del que este port deriva.
- Varios documentos de `docs/research/` lo citan.
- Permite comparar la arquitectura "compute-only" de Fedora con la de Ubuntu,
  que es distinta por necesidad: aquí hay una segunda GPU NVIDIA interna que
  funciona y no se puede romper.

**No se instala, no se construye y el CI no lo lintea.**
Lo que se usa hoy está en [`../../packaging/`](../../packaging/);
el estado real, en
[`../../docs/what-actually-works.md`](../../docs/what-actually-works.md).
