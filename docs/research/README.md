# Investigación histórica

> **Autoría de terceros.**
> Salvo este README, los documentos de este directorio son obra de
> [`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu) vía
> [`iecxiv/aorus-5060-egpu`](https://github.com/iecxiv/aorus-5060-egpu),
> bajo GPL-2.0.
> Ver [`../../CREDITS.md`](../../CREDITS.md).

Estos documentos son el registro de la investigación hecha sobre el stack
**Fedora** original (NUC 15 Pro+, RTX 5090, driver parcheado).
Se conservan porque el razonamiento y la evidencia siguen siendo valiosos:
el catálogo de levers, la metodología de captura y el ledger de hipótesis
explican *por qué* el proyecto tomó cada decisión.

> **No describen el estado actual.**
> En la máquina de referencia de hoy (ThinkPad P16 Gen 3, Ubuntu 26.04,
> RTX 5060 Ti) la eGPU funciona con `egpu-tb-fix` sobre el driver NVIDIA
> **stock**, sin ninguna de las palancas de este catálogo.
> El estado real está en [`../what-actually-works.md`](../what-actually-works.md).

## Referencias que apuntan fuera del repositorio

Al reestructurar el repo, parte del material que estos documentos citaban dejó
de estar en el árbol de trabajo.
Esas citas se dejaron **como texto, sin enlace**, para que la referencia siga
siendo legible sin fingir que el fichero está aquí:

- `archive/<caso>/` — los 79 MB de volcados de diagnóstico (dmesg, journal,
  configuraciones PCI, verdictos de hipótesis).
  Se movieron a `~/aorus-egpu-archive/` fuera del repositorio;
  el historial de git los conserva, así que `git log` y `git show` sobre
  commits anteriores a la reestructura siguen sirviéndolos.
- `.claude/projects/-root/memory/...` — notas de la sesión de trabajo de la
  máquina Fedora original.
  Nunca formaron parte de este repositorio.
- `services/ollama.md` — el servicio de integración con Ollama se retiró
  (ver [`service-retirement-roadmap.md`](./service-retirement-roadmap.md)).

Las citas a los parches **sí** se repararon:
viven en [`../../kernel/patches/`](../../kernel/patches/).

## Por dónde empezar

| Documento | Para qué |
|---|---|
| [`lever-catalog.md`](./lever-catalog.md) | El catálogo completo de palancas de fiabilidad, con su estado. |
| [`reliability-hypothesis-ledger.md`](./reliability-hypothesis-ledger.md) | El ledger de hipótesis: qué se probó, qué se falsificó y con qué evidencia. |
| [`tb4-pcie-topology.md`](./tb4-pcie-topology.md) | La topología real medida, y por qué los registros PCIe del túnel Thunderbolt son virtuales. |
| [`tb4-tunnel-gen1-investigation.md`](./tb4-tunnel-gen1-investigation.md) | La hipótesis H18, falsificada midiendo: la lección de "medir, no leer registros". |
| [`architecture-and-modularity.md`](./architecture-and-modularity.md) | Las capas L1-L7 y el coste de fork de cada una. |
| [`services/`](./services/) | Un documento por servicio del stack Fedora. |
