#pragma once

#include <string>

// Direct hardware register initialization for C-Media USB Audio adapters (CM108, CM6206, etc.)
// Replaces the need for vendor C-Media/Xear installer and utility software by writing directly
// to the USB HID interface registers.
namespace CmediaOpticalControl {

struct DeviceInfo {
    bool found = false;
    unsigned short vendorId = 0;
    unsigned short productId = 0;
    std::wstring devicePath;
    std::wstring productString;
};

// Scan for connected C-Media USB audio devices (VID 0x0D8C)
DeviceInfo FindCmediaDevice();

// Set S/PDIF output mode directly on C-Media chip registers via USB HID Output Report.
// REG0 address 0x00:
//   Bit 15: DMA Master to S/PDIF (1 = S/PDIF Out as master)
//   Bits 14-12: Sample rate (010 = 48 kHz)
bool EnableSpdifOutput(int sampleRate = 48000);

} // namespace CmediaOpticalControl
