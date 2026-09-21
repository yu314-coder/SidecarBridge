# Lossless compressed-frame storage optimization

H264Encoder previously allocated a zero-filled Data buffer and copied every compressed frame into it before transport packet assembly copied it again. EncodedVideoStorage now wraps contiguous CMBlockBuffer bytes in Data and retains the compressed block through the Data deallocator. It does not retain a capture pixel buffer or the entire CMSampleBuffer. Noncontiguous storage retains the copying fallback.

The returned data is treated as immutable encoder output. Payload bytes, SPS/PPS, keyframe requests, resolution, bitrate, frame-rate targets, encoder quality properties, transport encryption and bounded queue limits are unchanged. The optimization removes one payload allocation/copy at this boundary, not all transport copies. Retaining the original compressed allocation may have different allocator accounting from a copied payload; whole-app RSS reduction is not guaranteed.

## Evidence

- Apple documents the buffer lifetime contract: https://developer.apple.com/documentation/coremedia/cmblockbuffergetdatapointer(_:atoffset:lengthatoffsetout:totallengthout:datapointerout:)
- Three new tests cover retained lifetime/copy-on-write, fragmented-buffer byte equality and empty input.
- Optimized standalone benchmark, 20,000 iterations with 131,072 bytes each: copying 64.53 ms, retained storage 1.80 ms; matching checksums. This measures only storage conversion, not capture, encoding, encryption, UI or end-to-end FPS.
- Benchmark source/results: `/Volumes/D/build/SidecarBridge-storage-benchmark-20260916`.
- Initial full test run was interrupted after the unrelated Vision/OCR pairing-preview test stalled with allocation errors. All 152 remaining tests passed in a separate run excluding only that preview test; see `/Volumes/D/build/SidecarBridge-storage-tests-no-ocr-20260916.log`.

The installed Mac app has not been replaced and no App Store Connect upload was requested. Physical streaming CPU/RAM comparison remains necessary before claiming a whole-app percentage improvement.
