#ifndef COPENSSL_SHIM_H
#define COPENSSL_SHIM_H

#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/bn.h>
#include <openssl/asn1.h>

// OPENSSL_free is a macro, which Swift cannot call directly.
// Provide an inline wrapper function.
static inline void COpenSSL_free(void *ptr) {
    OPENSSL_free(ptr);
}

#endif
