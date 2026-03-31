import AppKit

// NX_KEYTYPE_PLAY from IOKit/hidsystem/ev_keymap.h
let nxKeyTypePlay: Int32 = 16

// Subtype value for NX input device events
let nxSystemDefinedSubtype: Int16 = 8

extension NSEvent {

    /// Returns true if this is a media play/pause key event.
    var isPlayPauseKey: Bool {
        guard type == .systemDefined,
              subtype.rawValue == nxSystemDefinedSubtype else {
            return false
        }
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        return keyCode == nxKeyTypePlay
    }

    /// Returns true if the media key event is a key-down (not key-up).
    var isMediaKeyDown: Bool {
        let keyFlags = Int32((data1 & 0x0000_FF00) >> 8)
        return keyFlags == 0x0A
    }
}
