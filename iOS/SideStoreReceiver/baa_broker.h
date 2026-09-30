/*
 * baa_broker.h — local Showcase BAA certificate/signing protocol.
 *
 * An entitled Showcase services helper obtains the DeviceIdentity certificate
 * before Personal Hotspot is enabled and keeps the SecKeyRef in memory.
 * Other root-owned Showcase processes retrieve the public certificate chain
 * and ask the broker to sign authentication challenges. The private key never
 * leaves the broker process.
 */

#ifndef SHOWCASE_BAA_BROKER_H
#define SHOWCASE_BAA_BROKER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

#define BAA_BROKER_PATH          "/tmp/showcase_baa.sock"
#define BAA_BROKER_MAGIC         "BAA3"
#define BAA_BROKER_HEADER_SIZE   12
#define BAA_BROKER_MAX_PAYLOAD   (64U * 1024U)

#define BAA_OP_GET_CERTS  1
#define BAA_OP_SIGN       2

#define BAA_STATUS_OK          0
#define BAA_STATUS_NOT_READY   1
#define BAA_STATUS_BAD_REQUEST 2
#define BAA_STATUS_SIGN_FAILED 3

static inline uint32_t baa_read_le32(const uint8_t *p) {
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static inline void baa_write_le32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

static inline bool baa_read_exact(int fd, void *buffer, size_t length) {
    uint8_t *p = (uint8_t *)buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t n = read(fd, p + done, length - done);
        if (n == 0) return false;
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        done += (size_t)n;
    }
    return true;
}

static inline bool baa_write_exact(int fd, const void *buffer, size_t length) {
    const uint8_t *p = (const uint8_t *)buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t n = write(fd, p + done, length - done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        done += (size_t)n;
    }
    return true;
}

static inline void baa_make_header(uint8_t header[BAA_BROKER_HEADER_SIZE],
                                   uint8_t opcode, uint8_t status,
                                   uint32_t payloadLength) {
    memcpy(header, BAA_BROKER_MAGIC, 4);
    header[4] = opcode;
    header[5] = status;
    header[6] = 0;
    header[7] = 0;
    baa_write_le32(header + 8, payloadLength);
}

static inline int baa_broker_connect(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, BAA_BROKER_PATH,
            sizeof(address.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static inline int baa_broker_request(uint8_t opcode,
                                     const uint8_t *request,
                                     uint32_t requestLength,
                                     uint8_t **response,
                                     uint32_t *responseLength) {
    if (!response || !responseLength ||
        requestLength > BAA_BROKER_MAX_PAYLOAD) return -1;
    *response = NULL;
    *responseLength = 0;

    int fd = baa_broker_connect();
    if (fd < 0) return -1;

    uint8_t header[BAA_BROKER_HEADER_SIZE];
    baa_make_header(header, opcode, 0, requestLength);
    if (!baa_write_exact(fd, header, sizeof(header)) ||
        (requestLength > 0 &&
         !baa_write_exact(fd, request, requestLength))) {
        close(fd);
        return -1;
    }

    if (!baa_read_exact(fd, header, sizeof(header)) ||
        memcmp(header, BAA_BROKER_MAGIC, 4) != 0 ||
        header[4] != opcode) {
        close(fd);
        return -1;
    }
    uint8_t status = header[5];
    uint32_t length = baa_read_le32(header + 8);
    if (length > BAA_BROKER_MAX_PAYLOAD) {
        close(fd);
        return -1;
    }

    uint8_t *payload = NULL;
    if (length > 0) {
        payload = (uint8_t *)malloc(length);
        if (!payload || !baa_read_exact(fd, payload, length)) {
            free(payload);
            close(fd);
            return -1;
        }
    }
    close(fd);

    if (status != BAA_STATUS_OK) {
        free(payload);
        return -(int)status - 1;
    }
    *response = payload;
    *responseLength = length;
    return 0;
}

static inline int baa_broker_get_certs(uint8_t **leaf, int *leafLength,
                                       uint8_t **intermediate,
                                       int *intermediateLength) {
    if (!leaf || !leafLength || !intermediate || !intermediateLength)
        return -1;
    *leaf = NULL;
    *intermediate = NULL;
    *leafLength = 0;
    *intermediateLength = 0;

    uint8_t *response = NULL;
    uint32_t responseLength = 0;
    int rc = baa_broker_request(BAA_OP_GET_CERTS, NULL, 0,
                                &response, &responseLength);
    if (rc != 0) return rc;
    if (responseLength < 8) {
        free(response);
        return -1;
    }

    uint32_t leafLen = baa_read_le32(response);
    uint32_t interLen = baa_read_le32(response + 4);
    if (leafLen == 0 || interLen == 0 ||
        leafLen > BAA_BROKER_MAX_PAYLOAD ||
        interLen > BAA_BROKER_MAX_PAYLOAD ||
        8U + leafLen + interLen != responseLength) {
        free(response);
        return -1;
    }

    uint8_t *leafCopy = (uint8_t *)malloc(leafLen);
    uint8_t *interCopy = (uint8_t *)malloc(interLen);
    if (!leafCopy || !interCopy) {
        free(leafCopy);
        free(interCopy);
        free(response);
        return -1;
    }
    memcpy(leafCopy, response + 8, leafLen);
    memcpy(interCopy, response + 8 + leafLen, interLen);
    free(response);

    *leaf = leafCopy;
    *leafLength = (int)leafLen;
    *intermediate = interCopy;
    *intermediateLength = (int)interLen;
    return 0;
}

static inline int baa_broker_sign(const uint8_t *message,
                                  uint32_t messageLength,
                                  uint8_t **signature,
                                  int *signatureLength) {
    if (!message || messageLength == 0 || !signature || !signatureLength)
        return -1;
    *signature = NULL;
    *signatureLength = 0;

    uint8_t *response = NULL;
    uint32_t responseLength = 0;
    int rc = baa_broker_request(BAA_OP_SIGN, message, messageLength,
                                &response, &responseLength);
    if (rc != 0) return rc;
    if (responseLength == 0 || responseLength > 1024) {
        free(response);
        return -1;
    }
    *signature = response;
    *signatureLength = (int)responseLength;
    return 0;
}

#endif
