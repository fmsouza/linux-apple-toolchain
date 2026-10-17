import Foundation

/// Builds the per-rendition CSI ("CTSI") record CoreUI binary-searches at
/// runtime: 184-byte header + TVL metadata block + body bytes.
///
/// Three orchestrators, one per rendition body kind. Each composes a header
/// (`CSIHeader`), a list of TVL entries (`TVLEntry` + `CSITVL`), and a body
/// (`MLECBody` for bitmaps, `DWAREnvelope` for preserved-source, an inline
/// COLR block for color).
enum CSIWriter {
    static func bitmap(name: String, body: BitmapBody, scaleFactor: UInt32) -> Data {
        let tvl = CSITVL.encode([
            .bitmapDescriptor(width: body.width, height: body.height),
            .destRect(width: body.width, height: body.height),
            .sliceScale(1),
            .bitmapFlag,
            .bytesPerRow(width: body.width),
        ])
        let payload = MLECBody.encode(width: body.width, height: body.height, pixelsBGRA: body.pixelsBGRA, opaque: body.isOpaque)

        // Bit 4 (0x10): generic-image category; set for `.image`, cleared
        // for `.appIcon`. Matches what UIImage(named:) walks for imageset
        // resolution.
        //
        // Bits 2 and 8 (0x104): set when this bitmap was rasterised from a
        // vector source (SVG / PDF). Matches actool's reference output for
        // SVG-rasterised bitmaps (flags=0x114 vs flags=0x10 for native PNG).
        // Bit 2 (0x04) is also set on the standalone vector source rendition
        // emitted from `preservedSource(.svg)`; the pair (0x04, 0x100)
        // together appears to mark "rendition is a raster derived from a
        // vector source", letting CoreUI's runtime branch into the
        // re-rasterise-from-vector path at non-intrinsic sizes.
        var renditionFlags: UInt32 = (body.kind == .image) ? 0x10 : 0x00
        if body.derivedFromVector {
            renditionFlags |= 0x104
        }

        let header = CSIHeader.encode(
            renditionFlags: renditionFlags,
            width: body.width,
            height: body.height,
            scaleFactor: scaleFactor,
            pixelFormat: CSIHeader.pixelFormatARGB,
            colorSpace: UInt32(body.colorSpaceID),
            layout: .bitmapIcon,
            name: body.renditionName,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + tvl + payload
    }

    /// Preserved-source rendition for `.svg` and `.jpg`. The CSI header is
    /// the same shape as for bitmaps (184 bytes) but several fields encode
    /// "not a decoded bitmap": dimensions, scaleFactor (for SVG), and
    /// colorSpace are all zero. The body is a DWAR envelope wrapping the
    /// original source bytes, with LZFSE compression for SVG and raw
    /// passthrough for JPG. Layout, pixelFormat, renditionFlags, and TVL
    /// shape all differ by source format.
    static func preservedSource(body: PreservedSourceBody, scaleFactor: UInt32) -> Data {
        let layout: CSIHeader.Layout
        let pixelFormat: UInt32
        let renditionFlags: UInt32
        let tvl: Data
        let envelope: Data
        switch body.format {
        case .svg:
            layout = .vector
            pixelFormat = CSIHeader.pixelFormatSVG
            // Bit 2 set; this distinguishes the vector category from the
            // generic-image bitmap category (bit 4) in the reference output.
            renditionFlags = 0x04
            // Trimmed TVL for vector renditions: only slice/scale and the
            // bitmap-count flag. Width, height, and bytes-per-row are not
            // meaningful for a scale-free vector source.
            tvl = CSITVL.encode([.sliceScale(1), .bitmapFlag])
            envelope = DWAREnvelope.encode(flags: 1, payload: LZFSE.encode([UInt8](body.sourceData)))
        case .jpeg(let width, let height):
            layout = .bitmapIcon
            pixelFormat = CSIHeader.pixelFormatJPEG
            // Same bit as generic-image bitmap; JPEG lives in the bitmap
            // category from CoreUI's classification standpoint.
            renditionFlags = 0x10
            // JPG TVL is the bitmap shape with bytes-per-row omitted: stride
            // is a strided-bitmap concept that has no analogue in a JPEG
            // bitstream (CoreUI consumes the JPG by decoding the SOS markers
            // itself).
            tvl = CSITVL.encode([
                .bitmapDescriptor(width: width, height: height),
                .destRect(width: width, height: height),
                .sliceScale(1),
                .bitmapFlag,
            ])
            envelope = DWAREnvelope.encode(flags: 0, payload: [UInt8](body.sourceData))
        }
        let header = CSIHeader.encode(
            renditionFlags: renditionFlags,
            // Width / height live in TVL 1001 for JPG; the CSI header carries
            // zeros for both preserved-source variants in the reference.
            width: 0,
            height: 0,
            scaleFactor: scaleFactor,
            pixelFormat: pixelFormat,
            colorSpace: 0,
            layout: layout,
            name: body.renditionName,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(envelope.count)
        )
        return header + tvl + envelope
    }

    /// Named color, as actool 27.0 writes it (measured on neutral colorsets):
    /// header scale and colorSpace 0, TVL `1004 = (0, 0)` and `1006 = 1`,
    /// bitmap count 1; body `COLR` (an LE multi-char constant, file bytes
    /// R,L,O,C), version 1, the color space ID, the component count, then the
    /// components as doubles (`ColorSetContents` parses them as actool does).
    /// Upstream wrote the tag as file bytes C,O,L,R with version 0, no TVL,
    /// scale 100 and the bitmap gamut ID: `assetutil` read that as one
    /// component (2e-323) in a "generic" space, and UIColor(named:) found no
    /// color.
    static func color(name: String, body: ColorBody) -> Data {
        let payload = colorBody(body: body)
        let tvl = CSITVL.encode([.sliceScale(0), .bitmapFlag])
        let header = CSIHeader.encode(
            renditionFlags: 0,
            width: 0,
            height: 0,
            scaleFactor: 0,
            pixelFormat: 0,
            colorSpace: 0,
            layout: .namedColor,
            name: name,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + tvl + payload
    }

    /// 'COLR' as an LE multi-char constant. Produces file bytes R,L,O,C.
    static let colorTag: UInt32 = 0x434F4C52

    private static func colorBody(body: ColorBody) -> Data {
        var w = ByteWriter()
        w.writeLE(colorTag)
        w.writeLE(UInt32(1))                    // version
        w.writeLE(UInt32(body.colorSpaceID))    // ColorSetContents.Color.colorSpaceID
        w.writeLE(UInt32(4))                    // numberOfComponents
        for component in [body.red, body.green, body.blue, body.alpha] {
            w.writeLE(component.bitPattern)
        }
        return w.data
    }
}
