// libFuzzer harness for rsync's wildcard matcher (lib/wildmatch.c), the engine behind every
// include/exclude/filter rule. Input = pattern, a NUL byte, then the text to match.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "wildmatch.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    const uint8_t *sep = memchr(data, 0, size);
    if (!sep)
        return -1;

    size_t plen = (size_t)(sep - data);
    size_t tlen = size - plen - 1;
    char *pattern = malloc(plen + 1);
    char *text = malloc(tlen + 1);
    if (!pattern || !text)
        abort();
    memcpy(pattern, data, plen);
    pattern[plen] = '\0';
    memcpy(text, sep + 1, tlen);
    text[tlen] = '\0';

    wildmatch(pattern, text);
    iwildmatch(pattern, text);

    free(pattern);
    free(text);
    return 0;
}
