// simple_flash.cpp
//
// Minimal single-angle plane-wave flash acquisition using the Verasonics
// Vantage NXT Acquisition SDK (VK_AcqSdk).
//
// Intended as the starting point for reproducing the MATLAB setup script
// (SetUpL38_22v_flashangles_firsthalf_PI_3d_stage_260120.m) in C++.
//
// Usage:
//   simple_flash [--trans L38-22v] [--frames 10] [--out rf_data.bin]
//
// Output: raw int16 RF data written as doubles (matching saveRF_issac_txt
//         fwrite(fid, RcvData{2}, 'double') format).
//
// Falls back to hardware emulation if no VDAS hardware is connected.

#include <VK_AcqSdk.h>
#include <VKU_AcqUtil.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

// ── Transducer defaults for L38-22v (matches MATLAB SetUp script) ─────────
static constexpr double kSpeedOfSound_mmpus = 1.540;
static constexpr double kStartDepth_mm      = 1.0;
static constexpr double kEndDepth_mm        = 39.0;
static constexpr int    kNumAngles          = 1;    // single plane-wave (na=1)
static constexpr double kSteerAngle_deg     = 0.0;  // normal incidence
static constexpr int    kDefaultFrames      = 10;
static constexpr double kTimeToNextAcq_us   = 220.0;
static constexpr double kTimeToNextFrame_us = 30000.0;

// ── Helpers ───────────────────────────────────────────────────────────────

static void check(VkResult r, const char* ctx)
{
    if (r != VkResult_Success) {
        std::cerr << "[simple_flash] " << ctx
                  << " failed: " << VK_ResultToString(r) << "\n";
        std::exit(EXIT_FAILURE);
    }
}

static VkResult selectFirstConnector(VkVdas vdas)
{
    int numConnectors = 0;
    VkResult r = VK_VdasGetAttribute(vdas, VkHWAttr_NumConnectors, &numConnectors);
    if (r != VkResult_Success || numConnectors == 0)
        return r;

    int mask = 0;
    r = VK_VdasGetAttribute(vdas, VkHWAttr_ConnectedMask, &mask);
    if (r != VkResult_Success)
        return r;

    return VK_VdasSelectConnectors(vdas, static_cast<unsigned int>(mask & 1));
}

static std::vector<VkReceive> notableReceives(VkVdas vdas)
{
    int n = 0;
    VK_VdasGetNotableReceives(vdas, 0, nullptr, &n);
    std::vector<VkReceive> rcvs(n);
    VK_VdasGetNotableReceives(vdas, n, rcvs.data(), &n);
    return rcvs;
}

// Kaiser window (for TX apodization)
static std::vector<double> kaiser(int n, double beta)
{
    std::vector<double> w(n);
    if (n == 1) { w[0] = 1.0; return w; }
    auto i0 = [](double x) {
        double s = 0, f = 1;
        for (int k = 0; k < 10; f *= ++k)
            s += std::pow(x / 2, 2 * k) / (f * f);
        return s;
    };
    for (int i = 0; i < n; ++i) {
        double x = (2.0 * i - (n - 1)) / (n - 1);
        w[i] = i0(beta * std::sqrt(1.0 - x * x)) / i0(beta);
    }
    return w;
}

// ── Sequence builder ──────────────────────────────────────────────────────

struct AcqParams {
    std::string transName     = "L38-22v";
    int         numFrames     = kDefaultFrames;
    int         numChannels   = 128;
    double      startDepth_mm = kStartDepth_mm;
    double      endDepth_mm   = kEndDepth_mm;
};

static VkSequence buildSequence(VkuTransducer trans,
                                const AcqParams& p,
                                VkBuffer* bufOut,
                                VkEvent*  startEventOut)
{
    double freq_MHz = 0.0;
    VKU_TransducerGetFrequency(trans, &freq_MHz);

    int    nElems   = 0;
    double spacing  = 0.0;
    VKU_TransducerGetNumElements(trans, &nElems);
    VKU_TransducerGetElementSpacing(trans, &spacing);

    // Row count: na * 4096 * 2 per the SDK flash_synchronous example
    const size_t rowsPerFrame = kNumAngles * 4096 * 2;

    VkBuffer buf = VK_INVALID_HANDLE;
    check(VK_BufferCreate(VkDT_Int16, (int)rowsPerFrame, p.numChannels,
                          1, p.numFrames, &buf),
          "VK_BufferCreate");

    VkReceiveFilter filter = VK_INVALID_HANDLE;
    check(VK_ReceiveFilterCreate(VkSM_NS200BW, freq_MHz, 0, 0, &filter),
          "VK_ReceiveFilterCreate");

    double startTime_us = p.startDepth_mm / kSpeedOfSound_mmpus;
    double acqLen_us    = std::ceil(
        std::sqrt(p.endDepth_mm * p.endDepth_mm +
                  std::pow((nElems - 1) * spacing, 2.0)) / kSpeedOfSound_mmpus);

    VkWaveform tw = VK_INVALID_HANDLE;
    check(VKU_WaveformCreateParametric(VkFreqCfg_Mid,
                                       {freq_MHz, 0.67, 2, 1}, &tw),
          "VKU_WaveformCreateParametric");

    VkSeqCtrl ctrlTTNA = VK_INVALID_HANDLE, ctrlTTNF = VK_INVALID_HANDLE;
    check(VK_SequenceControlCreateD(VkCmd_TimeToNextAcq, kTimeToNextAcq_us,  &ctrlTTNA),
          "SequenceControlCreateD TTNA");
    check(VK_SequenceControlCreateD(VkCmd_TimeToNextAcq, kTimeToNextFrame_us, &ctrlTTNF),
          "SequenceControlCreateD TTNF");

    VkAperture txAp = VK_INVALID_HANDLE;
    if (VKU_TransducerGetAperture(trans, 0, &txAp) != VkResult_Success)
        check(VK_ApertureCreateDefault(nElems, &txAp), "VK_ApertureCreateDefault");

    VkApod apod = VK_INVALID_HANDLE;
    check(VK_ApodCreate(nElems, 1.0, &apod), "VK_ApodCreate");
    auto apodVals = kaiser(nElems, 1.0);
    for (int i = 0; i < nElems; ++i)
        VK_ApodValue(apod, i, apodVals[i]);

    VkuPoint origin = {0.0, 0.0, 0.0};
    VkTransmit tx = VK_INVALID_HANDLE;
    check(VKU_TransmitCreateFocalDistance(trans, tw, apod, origin,
                                          0.0, kSteerAngle_deg, 0.0,
                                          kSpeedOfSound_mmpus, false, &tx),
          "VKU_TransmitCreateFocalDistance");
    check(VK_TransmitAperture(tx, txAp), "VK_TransmitAperture");

    VkSequence seq    = VK_INVALID_HANDLE;
    VkEvent firstEvt  = VK_INVALID_HANDLE;
    check(VK_SequenceCreate(&seq), "VK_SequenceCreate");

    for (int frame = 0; frame < p.numFrames; ++frame) {
        VkReceive rcv = VK_INVALID_HANDLE;
        check(VK_ReceiveCreate(startTime_us, acqLen_us, buf,
                               frame, 0, filter, &rcv),
              "VK_ReceiveCreate");

        VkSeqCtrl xfer = VK_INVALID_HANDLE;
        check(VK_SequenceControlCreateI(VkCmd_TransferToHost, frame, &xfer),
              "VK_SequenceControlCreateI TransferToHost");

        VkEvent evt = VK_INVALID_HANDLE;
        check(VK_EventCreate("flash", tx, rcv, &evt), "VK_EventCreate");

        if (firstEvt == VK_INVALID_HANDLE)
            firstEvt = evt;

        check(VK_EventAddControl(evt, ctrlTTNF), "VK_EventAddControl TTNF");
        check(VK_EventAddControl(evt, xfer),     "VK_EventAddControl xfer");
        check(VK_SequenceAddEvent(seq, evt),     "VK_SequenceAddEvent");
    }

    // Jump back to start for continuous loop (caller calls Stop after N frames)
    VkSeqCtrl jump = VK_INVALID_HANDLE;
    check(VK_SequenceControlCreateH(VkCmd_Jump, firstEvt, &jump), "VK_SequenceControlCreateH");
    VkEvent loopEvt = VK_INVALID_HANDLE;
    check(VK_EventCreate("loop", VK_HANDLE_NONE, VK_HANDLE_NONE, &loopEvt), "VK_EventCreate loop");
    check(VK_EventAddControl(loopEvt, jump),  "VK_EventAddControl jump");
    check(VK_SequenceAddEvent(seq, loopEvt),  "VK_SequenceAddEvent loop");

    *bufOut        = buf;
    *startEventOut = firstEvt;
    return seq;
}

// ── Save RF data ──────────────────────────────────────────────────────────
// Writes int16 RF samples cast to double, matching MATLAB saveRF_issac_txt:
//   fwrite(fid, RcvData{2}, 'double')

static bool saveRF(const char* path, VkBuffer buf, int numFrames)
{
    std::FILE* fid = std::fopen(path, "wb");
    if (!fid) {
        std::cerr << "[simple_flash] Cannot open output file: " << path << "\n";
        return false;
    }

    size_t frameBytes = 0;
    VK_BufferGetFrameSizeBytes(buf, &frameBytes);
    const size_t nSamples = frameBytes / sizeof(int16_t);

    std::vector<int16_t> raw(nSamples);
    std::vector<double>  dbl(nSamples);
    size_t totalWritten = 0;

    for (int f = 0; f < numFrames; ++f) {
        void* ptr = nullptr;
        if (VK_BufferLock(buf, f, &ptr) == VkResult_Success) {
            std::memcpy(raw.data(), ptr, frameBytes);
            VK_BufferUnlock(buf, f);
        }
        for (size_t i = 0; i < nSamples; ++i)
            dbl[i] = static_cast<double>(raw[i]);
        totalWritten += std::fwrite(dbl.data(), sizeof(double), nSamples, fid);
    }

    std::fclose(fid);
    std::printf("[simple_flash] Saved %zu samples (%d frames) to %s\n",
                totalWritten, numFrames, path);
    return true;
}

// ── main ──────────────────────────────────────────────────────────────────

int main(int argc, char** argv)
{
    // Minimal arg parsing (no third-party dep)
    std::string transName = "L38-22v";
    int         numFrames = kDefaultFrames;
    std::string outPath   = "rf_simple_flash.bin";

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--trans")  == 0 && i + 1 < argc) transName = argv[++i];
        if (std::strcmp(argv[i], "--frames") == 0 && i + 1 < argc) numFrames = std::atoi(argv[++i]);
        if (std::strcmp(argv[i], "--out")    == 0 && i + 1 < argc) outPath   = argv[++i];
    }

    std::printf("[simple_flash] trans=%s  frames=%d  out=%s\n",
                transName.c_str(), numFrames, outPath.c_str());

    check(VK_Initialize(),   "VK_Initialize");
    check(VKU_Initialize(),  "VKU_Initialize");

    VK_LoggerEnableConsole(true);
    VK_LoggerSetLevel(VkLL_Warn);

    // Connect to hardware; fall back to emulation if unavailable
    VkPlatformId platform = VkPID_Hardware;
    VkVdas vdas = VK_INVALID_HANDLE;
    VkResult r  = VK_VdasCreate(platform, 0, &vdas);
    if (r != VkResult_Success) {
        std::printf("[simple_flash] Hardware unavailable (%s) — using emulation\n",
                    VK_ResultToString(r));
        platform = VkPID_Emulation;
        check(VK_VdasCreate(platform, 0, &vdas), "VK_VdasCreate (emulation)");
    }

    int numChannels = 128;
    VK_VdasGetAttribute(vdas, VkHWAttr_NumReceiveChannels, &numChannels);
    VK_VdasProperty(vdas, VkProperty_WaitForProcessing, 1); // synchronous mode

    check(selectFirstConnector(vdas), "selectFirstConnector");

    VkuTransducer trans = VK_INVALID_HANDLE;
    if (platform == VkPID_Hardware) {
        r = VKU_TransducerGetConnected(vdas, 0, &trans);
        if (trans == VK_INVALID_HANDLE) {
            std::cerr << "[simple_flash] No transducer on connector 0 — trying by name\n";
            check(VKU_TransducerCreate(transName.c_str(), &trans), "VKU_TransducerCreate fallback");
        }
    } else {
        check(VKU_TransducerCreate(transName.c_str(), &trans), "VKU_TransducerCreate (emulation)");
    }

    AcqParams params;
    params.transName   = transName;
    params.numFrames   = numFrames;
    params.numChannels = numChannels;

    VkBuffer  rcvBuf    = VK_INVALID_HANDLE;
    VkEvent   startEvt  = VK_INVALID_HANDLE;
    VkSequence seq      = buildSequence(trans, params, &rcvBuf, &startEvt);

    // Set up channel mapping from transducer
    int connSize = 0;
    if (VKU_TransducerGetConnector(trans, 0, nullptr, &connSize) == VkResult_Success && connSize > 0) {
        std::vector<int> chMap(connSize);
        if (VKU_TransducerGetConnector(trans, connSize, chMap.data(), &connSize) == VkResult_Success)
            VK_VdasChannelMapping(vdas, connSize, chMap.data());
    }

    check(VK_VdasSequenceLoad(vdas, seq),         "VK_VdasSequenceLoad");
    check(VK_VdasSequenceStart(vdas, startEvt),   "VK_VdasSequenceStart");

    std::printf("[simple_flash] Acquiring %d frames...\n", numFrames);

    auto rcvFrames = notableReceives(vdas);
    for (auto rcv : rcvFrames) {
        r = VK_VdasWaitForReceive(vdas, rcv, 1000 /*ms*/);
        if (r == VkResult_Success) {
            int frameIdx = 0;
            VK_ReceiveGetFrameIndex(rcv, &frameIdx);
            std::printf("[simple_flash] Received frame %d\n", frameIdx);
            VK_VdasMarkReceiveProcessed(vdas, rcv);
        } else {
            std::cerr << "[simple_flash] WaitForReceive failed: "
                      << VK_ResultToString(r) << "\n";
        }
    }

    check(VK_VdasSequenceStop(vdas), "VK_VdasSequenceStop");
    VK_VdasSequenceUnload(vdas);

    saveRF(outPath.c_str(), rcvBuf, numFrames);

    VK_SequenceDestroy(seq);
    VK_VdasDestroy(vdas);
    VKU_Shutdown();
    VK_Shutdown();

    return EXIT_SUCCESS;
}
