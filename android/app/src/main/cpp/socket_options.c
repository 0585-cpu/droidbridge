#include <jni.h>
#include <sys/socket.h>

/* Read only, using an owned duplicate supplied by the public ParcelFileDescriptor API. */
int db_socket_option_matches(int fd, int level, int option, int expected) {
    int actual = 0;
    socklen_t size = sizeof(actual);
    return getsockopt(fd, level, option, &actual, &size) == 0 &&
           size == sizeof(actual) && actual == expected;
}

JNIEXPORT jboolean JNICALL
Java_io_droidbridge_network_NativeSocketOptions_matches(JNIEnv *env, jobject self,
                                                       jint fd, jint level, jint option, jint expected) {
    (void)env;
    (void)self;
    return db_socket_option_matches(fd, level, option, expected) ? JNI_TRUE : JNI_FALSE;
}
