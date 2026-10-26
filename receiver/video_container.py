"""Bounded MP4/QuickTime envelope checks; never decode media or alter bytes."""


class VideoContainerError(ValueError):
    pass


MP4_BRANDS = {b"isom", b"iso2", b"iso3", b"iso4", b"iso5", b"iso6",
              b"mp41", b"mp42", b"avc1", b"hvc1", b"hev1", b"M4V ", b"MSNV"}
IMAGE_BRANDS = {b"avif", b"avis", b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1",
                b"heim", b"heis", b"hevm", b"hevs"}
VIDEO_SAMPLES = {b"avc1", b"avc3", b"hvc1", b"hev1", b"mp4v", b"av01", b"vp09",
                 b"jpeg", b"mjpa", b"mjpb", b"ap4h", b"ap4x", b"apch", b"apcn", b"apcs", b"apco"}


def video_extension(data):
    """Return mp4/mov for a supported video envelope, None for other formats.

    A declared video container with malformed metadata raises instead of falling
    back to image decoding. This validates structure, not playback or codecs.
    """
    view = memoryview(data)
    if len(view) < 8 or view[4:8] not in (b"ftyp", b"free", b"skip", b"wide"):
        return None
    visited = 0

    def fail():
        raise VideoContainerError("Malformed or unsupported MP4/MOV video envelope")

    def boxes(start, end):
        nonlocal visited
        result = []
        while start < end:
            visited += 1
            if visited > 4096 or end-start < 8:
                fail()
            size = int.from_bytes(view[start:start+4], "big")
            kind = bytes(view[start+4:start+8])
            header = 8
            if size == 1:
                if end-start < 16:
                    fail()
                size = int.from_bytes(view[start+8:start+16], "big")
                header = 16
            elif size == 0:
                size = end-start
            if size < header or size > end-start:
                fail()
            result.append((kind, start+header, start+size))
            start += size
        return result

    def only(items, kind, required=True):
        found = [item for item in items if item[0] == kind]
        if len(found) > 1 or required and not found:
            fail()
        return found[0] if found else None

    top = boxes(0, len(view))
    ftyp = only(top, b"ftyp", required=False)
    if ftyp is None:
        return None
    _, start, end = ftyp
    if end-start < 8 or (end-start) % 4 or end-start > 4096:
        fail()
    major = bytes(view[start:start+4])
    brands = {major} | {bytes(view[i:i+4]) for i in range(start+8, end, 4)}
    if brands & IMAGE_BRANDS or not brands & (MP4_BRANDS | {b"qt  "}):
        return None
    moov = only(top, b"moov")
    if not any(kind == b"mdat" and end > start for kind, start, end in top):
        fail()
    tracks = [item for item in boxes(moov[1], moov[2]) if item[0] == b"trak"]
    if not 1 <= len(tracks) <= 256:
        fail()
    found_video = False
    for _, begin, finish in tracks:
        mdia = only(boxes(begin, finish), b"mdia")
        media = boxes(mdia[1], mdia[2])
        hdlr = only(media, b"hdlr")
        if hdlr[2]-hdlr[1] < 24:
            fail()
        if view[hdlr[1]+8:hdlr[1]+12] != b"vide":
            continue
        minf = only(media, b"minf")
        stbl = only(boxes(minf[1], minf[2]), b"stbl")
        stsd = only(boxes(stbl[1], stbl[2]), b"stsd")
        if stsd[2]-stsd[1] < 8 or view[stsd[1]:stsd[1]+4] != bytes(4):
            fail()
        declared = int.from_bytes(view[stsd[1]+4:stsd[1]+8], "big")
        samples = boxes(stsd[1]+8, stsd[2])
        if not 1 <= declared <= 256 or len(samples) != declared:
            fail()
        for codec, begin, finish in samples:
            if codec not in VIDEO_SAMPLES or finish-begin < 78:
                fail()
            if (not int.from_bytes(view[begin+6:begin+8], "big") or
                    not int.from_bytes(view[begin+24:begin+26], "big") or not int.from_bytes(view[begin+26:begin+28], "big")):
                fail()
        found_video = True
    if not found_video:
        raise VideoContainerError("MP4/MOV recording must contain a supported video track; audio-only files are not supported")
    return "mov" if major == b"qt  " else "mp4"
