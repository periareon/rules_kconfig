/* A program the wasi-sdk toolchain of `@wasi_sdk` compiles and links for
 * `wasm32-wasip1`, so that both halves of the toolchain are exercised:
 * `bazel build --config=wasm32 //tools/wasi_sdk/test:hello`. */
#include <stdio.h>

int main(void) {
    printf("hello from wasm32-wasip1\n");
    return 0;
}
