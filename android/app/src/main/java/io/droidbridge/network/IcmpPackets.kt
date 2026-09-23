package io.droidbridge.network

import io.droidbridge.protocol.IcmpRequest

object IcmpPackets {
    fun checksum(bytes: ByteArray): Int {
        var sum=0
        var i=0
        while(i<bytes.size) { sum+=(bytes[i].toInt() and 255) shl 8; if(i+1<bytes.size) sum+=bytes[i+1].toInt() and 255; i+=2 }
        while(sum shr 16 != 0) sum=(sum and 65535)+(sum ushr 16)
        return sum.inv() and 65535
    }
    fun request(request: IcmpRequest): ByteArray {
        require(request.family in listOf(4,6) && request.payload.size<=1200 && request.ttl in 0..255)
        return (byteArrayOf(if(request.family==4) 8 else 128.toByte(),0,0,0,0,0,(request.requestId ushr 8).toByte(),request.requestId.toByte())+request.payload).also {
            if(request.family==4) { val checksum=checksum(it); it[2]=(checksum shr 8).toByte(); it[3]=checksum.toByte() }
        }
    }
    fun matches(bytes: ByteArray,request: IcmpRequest): Boolean = bytes.size==request.payload.size+8 &&
        (bytes[0].toInt() and 255) == (if(request.family==4) 0 else 129) && bytes[1]==0.toByte() &&
        bytes[6]==(request.requestId ushr 8).toByte() && bytes[7]==request.requestId.toByte() &&
        bytes.copyOfRange(8,bytes.size).contentEquals(request.payload)
}
