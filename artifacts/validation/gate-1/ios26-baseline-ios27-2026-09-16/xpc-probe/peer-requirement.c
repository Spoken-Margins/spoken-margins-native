#include <xpc/xpc.h>
#include <stdio.h>
#include <stdlib.h>

// Exercise the C API beneath Swift XPCPeerRequirement.hasEntitlement.
// It reports an error without Swift's assertion on a failed construction.
int main(void) {
    const char *names[] = {
        "com.apple.private.appintents.live-entities.read",
        "com.apple.private.appintents.live-entities.write",
        "com.apple.security.app-sandbox"
    };
    int failures = 0;
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        xpc_rich_error_t error = NULL;
        xpc_peer_requirement_t requirement =
            xpc_peer_requirement_create_entitlement_exists(names[i], &error);
        printf("%s: %s\n", names[i], requirement ? "created" : "FAILED");
        if (error) {
            char *description = xpc_rich_error_copy_description(error);
            printf("error: %s\n", description);
            free(description);
            xpc_release(error);
        }
        if (requirement) xpc_release(requirement); else failures++;
    }
    return failures ? 1 : 0;
}
