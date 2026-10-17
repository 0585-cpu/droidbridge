package io.droidbridge.network

/** Public NDK getsockopt fills the getter missing from the public android.system.Os API. */
internal object NativeSocketOptions {
    init { System.loadLibrary("droidbridge_socket_options") }
    external fun matches(fd: Int,level: Int,option: Int,expected: Int): Boolean
}
