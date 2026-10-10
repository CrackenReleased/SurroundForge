#include "CmediaOpticalControl.h"

#include <windows.h>
#include <setupapi.h>
#include <initguid.h>
#include <hidsdi.h>
#include <iostream>
#include <vector>

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "hid.lib")

namespace CmediaOpticalControl {

constexpr unsigned short CMEDIA_VID = 0x0D8C;

DeviceInfo FindCmediaDevice() {
    DeviceInfo info;
    GUID hidGuid;
    HidD_GetHidGuid(&hidGuid);

    HDEVINFO devInfo = SetupDiGetClassDevsW(&hidGuid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devInfo == INVALID_HANDLE_VALUE) {
        return info;
    }

    SP_DEVICE_INTERFACE_DATA devInterfaceData{};
    devInterfaceData.cbSize = sizeof(SP_DEVICE_INTERFACE_DATA);

    for (DWORD index = 0; SetupDiEnumDeviceInterfaces(devInfo, nullptr, &hidGuid, index, &devInterfaceData); ++index) {
        DWORD requiredSize = 0;
        SetupDiGetDeviceInterfaceDetailW(devInfo, &devInterfaceData, nullptr, 0, &requiredSize, nullptr);
        if (requiredSize == 0) continue;

        std::vector<BYTE> detailBuffer(requiredSize);
        auto* detailData = reinterpret_cast<PSP_DEVICE_INTERFACE_DETAIL_DATA_W>(detailBuffer.data());
        detailData->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);

        if (!SetupDiGetDeviceInterfaceDetailW(devInfo, &devInterfaceData, detailData, requiredSize, nullptr, nullptr)) {
            continue;
        }

        HANDLE hDevice = CreateFileW(
            detailData->DevicePath,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            0,
            nullptr
        );

        if (hDevice == INVALID_HANDLE_VALUE) {
            // Try query access without read/write
            hDevice = CreateFileW(
                detailData->DevicePath,
                0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                nullptr,
                OPEN_EXISTING,
                0,
                nullptr
            );
        }

        if (hDevice != INVALID_HANDLE_VALUE) {
            HIDD_ATTRIBUTES attr{};
            attr.Size = sizeof(HIDD_ATTRIBUTES);
            if (HidD_GetAttributes(hDevice, &attr)) {
                if (attr.VendorID == CMEDIA_VID) {
                    info.found = true;
                    info.vendorId = attr.VendorID;
                    info.productId = attr.ProductID;
                    info.devicePath = detailData->DevicePath;

                    wchar_t prodBuffer[256] = {0};
                    if (HidD_GetProductString(hDevice, prodBuffer, sizeof(prodBuffer))) {
                        info.productString = prodBuffer;
                    }
                    CloseHandle(hDevice);
                    break;
                }
            }
            CloseHandle(hDevice);
        }
    }

    SetupDiDestroyDeviceInfoList(devInfo);
    return info;
}

bool EnableSpdifOutput(int sampleRate) {
    GUID hidGuid;
    HidD_GetHidGuid(&hidGuid);

    HDEVINFO devInfo = SetupDiGetClassDevsW(&hidGuid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devInfo == INVALID_HANDLE_VALUE) {
        return false;
    }

    SP_DEVICE_INTERFACE_DATA devInterfaceData{};
    devInterfaceData.cbSize = sizeof(SP_DEVICE_INTERFACE_DATA);
    bool success = false;

    // S/PDIF configuration report for CM6206 / CM108
    // Byte 0: 0x20 (Write internal register)
    // Byte 1: 0x00 (DATAL)
    // Byte 2: DATAH:
    //   Bit 15: 1 = DMA Master to S/PDIF
    //   Bits 14-12: Sample rate:
    //     000 = 44.1 kHz (0x80)
    //     010 = 48.0 kHz (0xA0)
    //     110 = 96.0 kHz (0xE0)
    // Byte 3: 0x00 (REG0 - S/PDIF Control)
    BYTE rateBits = 0x20; // default 48 kHz
    if (sampleRate == 44100) rateBits = 0x00;
    else if (sampleRate == 96000) rateBits = 0x60;

    BYTE dataH = static_cast<BYTE>(0x80 | rateBits); // Bit 15 set + sample rate

    // Standard 4-byte report
    BYTE report4[4] = { 0x20, 0x00, dataH, 0x00 };
    // 5-byte report with Report ID 0 (required by some Windows HID drivers)
    BYTE report5[5] = { 0x00, 0x20, 0x00, dataH, 0x00 };

    for (DWORD index = 0; SetupDiEnumDeviceInterfaces(devInfo, nullptr, &hidGuid, index, &devInterfaceData); ++index) {
        DWORD requiredSize = 0;
        SetupDiGetDeviceInterfaceDetailW(devInfo, &devInterfaceData, nullptr, 0, &requiredSize, nullptr);
        if (requiredSize == 0) continue;

        std::vector<BYTE> detailBuffer(requiredSize);
        auto* detailData = reinterpret_cast<PSP_DEVICE_INTERFACE_DETAIL_DATA_W>(detailBuffer.data());
        detailData->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);

        if (!SetupDiGetDeviceInterfaceDetailW(devInfo, &devInterfaceData, detailData, requiredSize, nullptr, nullptr)) {
            continue;
        }

        HANDLE hDevice = CreateFileW(
            detailData->DevicePath,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_EXISTING,
            0,
            nullptr
        );

        if (hDevice != INVALID_HANDLE_VALUE) {
            HIDD_ATTRIBUTES attr{};
            attr.Size = sizeof(HIDD_ATTRIBUTES);
            if (HidD_GetAttributes(hDevice, &attr)) {
                if (attr.VendorID == CMEDIA_VID) {
                    // Send HID Output report to configure S/PDIF registers
                    BOOLEAN ok = HidD_SetOutputReport(hDevice, report5, sizeof(report5));
                    if (!ok) {
                        ok = HidD_SetOutputReport(hDevice, report4, sizeof(report4));
                    }
                    if (!ok) {
                        DWORD bytesWritten = 0;
                        ok = WriteFile(hDevice, report5, sizeof(report5), &bytesWritten, nullptr);
                        if (!ok) {
                            ok = WriteFile(hDevice, report4, sizeof(report4), &bytesWritten, nullptr);
                        }
                    }

                    if (ok) {
                        std::wcout << L"[CmediaOpticalControl] Successfully initialized S/PDIF at "
                                   << sampleRate << L" Hz on C-Media VID 0x" << std::hex << attr.VendorID
                                   << L" PID 0x" << attr.ProductID << std::dec << std::endl;
                        success = true;
                    }
                }
            }
            CloseHandle(hDevice);
        }
    }

    SetupDiDestroyDeviceInfoList(devInfo);
    return success;
}

} // namespace CmediaOpticalControl
