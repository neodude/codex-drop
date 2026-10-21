package guide.guidelabs.codexdrop.platform

import java.io.InputStream

/** Small private metadata files, including on API 28 where readNBytes is unavailable. */
internal fun InputStream.readLimited(limit: Int): ByteArray {
    val data = ByteArray(limit + 1)
    var offset = 0
    while (offset < data.size) {
        val count = read(data,offset,data.size - offset)
        if (count == -1) break
        if (count == 0) continue
        offset += count
    }
    require(offset <= limit)
    return data.copyOf(offset)
}
