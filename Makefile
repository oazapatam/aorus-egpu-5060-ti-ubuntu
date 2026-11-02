# Makefile — puerta de entrada para construir los .deb de este repo.
#
# Los .deb salen en dist/ y NO se versionan. La lógica de empaquetado vive en
# scripts/build-*.sh (fuente única); este Makefile solo es comodidad.
#
#   make              -> paquetes soportados (tb-fix + forensics)
#   make tb-fix       -> egpu-tb-fix            (PRINCIPAL, verificado en vivo)
#   make forensics    -> aorus-egpu-forensics   (depurar cuelgues del host)
#   make overclock    -> aorus-egpu-overclock   (EN DESARROLLO, sin validar)
#   make config       -> aorus-egpu-config      (SUPERSEDED, archivo)
#   make dkms         -> aorus-egpu-nvidia-dkms (SUPERSEDED + requiere rebase; RED)
#   make ci           -> CI LOCAL COMPLETO (todas las etapas de ci/)
#   make ci-list      -> lista las etapas de CI
#   make lint         -> sintaxis de todo el shell del repo
#   make test         -> tests del dominio (sin root, sin GPU)
#   make inspect      -> dpkg-deb -I/-c de lo construido
#   make clean        -> borra dist/ y los árboles ensamblados
#
# `make` NO construye los paquetes SUPERSEDED: aorus-egpu-config se pisaría con
# egpu-tb-fix, y el DKMS está fijado a un driver que ya no es el instalado
# (ver docs/what-actually-works.md). Tampoco construye overclock: está sin
# validar en hardware todavía.

SHELL := /bin/bash
DIST  := dist

.PHONY: all tb-fix forensics overclock config dkms ci ci-list lint test inspect clean

# El CI local vive en ci/ (una etapa por fichero, ci/NN-*.sh) y lo orquesta
# ci/run.sh, que ordena por número, no se para en el primer fallo y distingue
# "etapa omitida por falta de herramienta" de "etapa en rojo".
# Los hooks de git lo reutilizan, para que local y pre-commit no divergan.
ci:
	@bash ci/run.sh

ci-list:
	@bash ci/run.sh --list

all: tb-fix forensics

forensics: lint
	@bash scripts/build-forensics.sh

tb-fix: lint
	@bash scripts/build-tb-fix.sh

overclock: lint test
	@bash scripts/build-overclock.sh

config: lint
	@bash scripts/build-config.sh

dkms: lint
	@bash scripts/build-dkms.sh

# Atajos a las etapas de CI correspondientes, para no tener dos definiciones de
# "qué es lint" y "qué es test" que se puedan desincronizar.
lint:
	@bash ci/10-shell-syntax.sh

test:
	@bash ci/30-unit-tests.sh

inspect:
	@set -e; shopt -s nullglob; debs=($(DIST)/*.deb); \
	if [ $${#debs[@]} -eq 0 ]; then echo "No hay .deb en $(DIST)/ (corre 'make')"; exit 0; fi; \
	for d in "$${debs[@]}"; do \
	  echo "===== $$d ====="; \
	  dpkg-deb -I "$$d" | sed -n '/Package:/,/Description:/p'; \
	  echo "--- archivos ---"; dpkg-deb -c "$$d"; echo; \
	done

clean:
	@rm -rf $(DIST) build
	@rm -rf packaging/aorus-egpu-overclock/usr/lib/aorus-egpu
	@rm -f  packaging/aorus-egpu-overclock/usr/sbin/aorus-egpu-oc
	@rm -rf packaging/aorus-egpu-forensics/usr/lib/aorus-egpu
	@rm -f  packaging/aorus-egpu-forensics/usr/sbin/aorus-egpu-probe
	@rm -f  packaging/aorus-egpu-forensics/usr/sbin/aorus-egpu-postmortem
	@rm -rf packaging/aorus-egpu-nvidia-dkms/usr
	@echo "limpio: dist/, build/ y árboles ensamblados"
