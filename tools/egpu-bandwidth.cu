// egpu-bandwidth — mide el ancho de banda real host<->eGPU sobre Thunderbolt.
//
// POR QUÉ EXISTE: en una eGPU los puentes del túnel Thunderbolt VIRTUALIZAN sus
// registros PCIe y anuncian "Gen1 2.5GT/s" sea cual sea la capacidad real del
// túnel. El mensaje del kernel "N Gb/s available PCIe bandwidth, limited by
// 2.5 GT/s" lee esos registros virtuales: NO es una medición. Concluir que hay
// un techo de Gen1 a partir de lspci ya llevó a una hipótesis falsificada en
// este proyecto (H18, ver docs/research/tb4-tunnel-gen1-investigation.md).
//
// La regla del repo es: MEDIR antes de investigar un techo de ancho de banda.
// Esta herramienta es la forma barata de hacerlo, sin dependencias (no necesita
// nvbandwidth, cmake ni boost).
//
// Selecciona la GPU por PCI bus-id para no medir nunca la GPU interna por error.
//
// Compilar:  nvcc -O2 -o tools/egpu-bandwidth tools/egpu-bandwidth.cu
// Usar:      tools/egpu-bandwidth            (primera GPU externa que encuentre)
//            tools/egpu-bandwidth B4:00.0    (bus-id concreto)
//
// Referencia de interpretación en esta clase de hardware:
//   ~2.5-3.3 GB/s  = túnel TB4/TB5 saturado; NO hay techo que levantar.
//   ~1.0 GB/s      = techo real de Gen1 x4; el tramo PCIe real está degradado.

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e=(x); if(e!=cudaSuccess){ \
  fprintf(stderr,"CUDA error %s en %s:%d\n",cudaGetErrorString(e),__FILE__,__LINE__); \
  return 2; } } while(0)

static const size_t MB = 1024ull*1024ull;

int main(int argc, char** argv) {
    const char* want = (argc > 1) ? argv[1] : nullptr;

    int n = 0;
    CK(cudaGetDeviceCount(&n));
    if (n == 0) { fprintf(stderr, "no hay GPUs CUDA.\n"); return 1; }

    int dev = -1;
    char busid[64] = {0};
    for (int i = 0; i < n; ++i) {
        cudaDeviceProp p;
        CK(cudaGetDeviceProperties(&p, i));
        char b[64];
        CK(cudaDeviceGetPCIBusId(b, sizeof b, i));
        bool match;
        if (want) {
            // Coincidencia por sufijo: acepta "B4:00.0" y "0000:B4:00.0".
            size_t lb = strlen(b), lw = strlen(want);
            match = (lw <= lb) && (strcasecmp(b + (lb - lw), want) == 0);
        } else {
            // Sin argumento: la primera GPU que NO sea la integrada/interna.
            // `integrated` no basta en este host (ambas son discretas), así que
            // se usa el nombre: la externa es la GeForce, la interna la RTX PRO.
            match = (strstr(p.name, "GeForce") != nullptr);
        }
        printf("GPU %d  %-42s %s%s\n", i, p.name, b, match ? "   <-- elegida" : "");
        if (match && dev < 0) { dev = i; snprintf(busid, sizeof busid, "%s", b); }
    }
    if (dev < 0) { fprintf(stderr, "\nno encontré la GPU pedida.\n"); return 1; }
    printf("\nmidiendo sobre %s (bus %s)\n\n", "GPU elegida", busid);
    CK(cudaSetDevice(dev));

    const size_t bytes = 256 * MB;
    const int iters = 20, warmup = 3;

    void *h = nullptr, *d = nullptr;
    // Memoria PINNED: sin ella se mide el coste del staging del driver, no el
    // enlace. Es la diferencia entre medir el bus y medir malloc.
    CK(cudaHostAlloc(&h, bytes, cudaHostAllocDefault));
    CK(cudaMalloc(&d, bytes));
    memset(h, 0xA5, bytes);

    cudaEvent_t a, b;
    CK(cudaEventCreate(&a)); CK(cudaEventCreate(&b));

    struct { const char* name; cudaMemcpyKind kind; } tests[] = {
        { "host -> eGPU (H2D)", cudaMemcpyHostToDevice },
        { "eGPU -> host (D2H)", cudaMemcpyDeviceToHost },
    };

    for (auto& t : tests) {
        for (int i = 0; i < warmup; ++i)
            CK(cudaMemcpy(t.kind == cudaMemcpyHostToDevice ? d : h,
                          t.kind == cudaMemcpyHostToDevice ? h : d, bytes, t.kind));
        CK(cudaDeviceSynchronize());
        CK(cudaEventRecord(a));
        for (int i = 0; i < iters; ++i)
            CK(cudaMemcpy(t.kind == cudaMemcpyHostToDevice ? d : h,
                          t.kind == cudaMemcpyHostToDevice ? h : d, bytes, t.kind));
        CK(cudaEventRecord(b));
        CK(cudaEventSynchronize(b));
        float ms = 0; CK(cudaEventElapsedTime(&ms, a, b));
        double gbs = (double)bytes * iters / (ms / 1000.0) / 1e9;
        printf("  %-22s %6.2f GB/s   (%.1f Gb/s)\n", t.name, gbs, gbs * 8);
    }

    CK(cudaFreeHost(h)); CK(cudaFree(d));
    printf("\nInterpretación: ~2.5-3.3 GB/s = túnel TB saturado (sin techo que\n"
           "levantar). ~1.0 GB/s = techo real de Gen1 x4.\n");
    return 0;
}
