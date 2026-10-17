package io.droidbridge.network

import java.io.ByteArrayOutputStream

/** Bounded DNS name reader, including pointer-loop rejection. Names live only for this request. */
internal object DnsQuestions {
    data class Question(val name: String,val type: Int,val klass: Int)
    private fun bad(): Nothing=throw DnsFailureException(DnsFailure.MALFORMED)
    private fun u16(packet: ByteArray,offset: Int): Int { if(offset<0 || offset+2>packet.size) bad(); return ((packet[offset].toInt() and 255) shl 8) or (packet[offset+1].toInt() and 255) }
    private fun name(packet: ByteArray,start: Int): Pair<String,Int> {
        var offset=start; var end=-1; val visited=mutableSetOf<Int>(); val labels=mutableListOf<String>(); var size=0
        while(true) {
            if(offset !in packet.indices || !visited.add(offset) || visited.size>128) bad()
            val length=packet[offset].toInt() and 255
            if(length==0) return labels.joinToString(".") to if(end>=0) end else offset+1
            if(length and 0xc0 == 0xc0) {
                val pointer=u16(packet,offset) and 0x3fff
                if(end<0) end=offset+2
                offset=pointer; continue
            }
            if(length>63 || offset+1+length>packet.size) bad()
            size+=length+1; if(size>254) bad()
            labels+=String(packet,offset+1,length,Charsets.ISO_8859_1)
            offset+=length+1
        }
    }
    fun read(packet: ByteArray): List<Question> {
        DnsWire.validateForwardable(packet)
        val count=u16(packet,4); if(count !in 1..16 || DnsWire.isResponse(packet)) bad()
        var offset=12
        return List(count) { val (name,end)=name(packet,offset); val type=u16(packet,end); val klass=u16(packet,end+2); offset=end+4; Question(name,type,klass) }
    }
    fun emptyResponse(packet: ByteArray,questions: List<Question>,rcode: Int): ByteArray {
        val out=ByteArrayOutputStream()
        val header=packet.copyOf(12)
        header[2]=((header[2].toInt() and 1) or 0x80).toByte()
        header[3]=((header[3].toInt() and 0x10) or 0x80 or rcode).toByte()
        for(i in 6..11) header[i]=0
        out.write(header)
        for(q in questions) {
            for(label in q.name.split('.').filter { it.isNotEmpty() }) { val bytes=label.toByteArray(Charsets.ISO_8859_1); out.write(bytes.size); out.write(bytes) }
            out.write(0); out.write(q.type shr 8); out.write(q.type); out.write(q.klass shr 8); out.write(q.klass)
        }
        return out.toByteArray()
    }
    fun containsAaaaAnswer(packet: ByteArray): Boolean {
        var offset=12
        repeat(u16(packet,4).also { if(it>16) bad() }) { val (_,end)=name(packet,offset); u16(packet,end+2); offset=end+4 }
        // Incidental IPv6 glue must not erase an otherwise usable A/SRV/MX answer.
        // Keep offsets and arbitrary RDATA untouched; only the answer section is gated.
        val count=u16(packet,6)
        if(count>256) bad()
        repeat(count) {
            val (_,end)=name(packet,offset)
            val type=u16(packet,end); val length=u16(packet,end+8)
            if(end+10+length>packet.size) bad()
            if(type==28) return true
            offset=end+10+length
        }
        return false
    }
}
