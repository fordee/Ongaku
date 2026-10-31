//
//  OngakuEffectsParameterAddresses.h
//  OngakuEffects
//

#pragma once

#include <AudioToolbox/AUParameters.h>

/// The effects in the extension. Each is its own Audio Unit (its own subtype), and the
/// kernel runs the one it was created as.
typedef NS_ENUM(int, OngakuEffectKind) {
  OngakuEffectKindChannelEQ = 0,
  OngakuEffectKindCompressor = 1,
  OngakuEffectKindReverb = 2,
  OngakuEffectKindDelay = 3,
  OngakuEffectKindRetroSynth = 4,
  OngakuEffectKindDrumMachine = 5,
  OngakuEffectKindSampler = 6,
  OngakuEffectKindNoiseGate = 7,
  OngakuEffectKindTransientShaper = 8,
  OngakuEffectKindMaximizer = 9,
  OngakuEffectKindDeEsser = 10,
  OngakuEffectKindSaturation = 11,
  OngakuEffectKindDoubler = 12,
  OngakuEffectKindConvolutionReverb = 13,
  OngakuEffectKindVocalStrip = 14,
  OngakuEffectKindSessionDrummer = 15,
  OngakuEffectKindMastering = 16,
};

/// Every effect's parameters, each effect in its own range of a hundred addresses.
typedef NS_ENUM(AUParameterAddress, OngakuEffectsParameterAddress) {
  // Channel EQ (0–99): the output gain, then eight bands of five fields each, band b's
  // field f at eqFirstBand + eqBandStride * b + f.
  eqOutputGain = 0,
  eqFirstBand = 10,

  // Compressor (100–199).
  compThreshold = 100,
  compRatio = 101,
  compAttack = 102,
  compRelease = 103,
  compKnee = 104,
  compMakeUp = 105,
  compAutoGain = 106,
  compMix = 107,
  /// 0 for peak, 1 for RMS.
  compDetection = 108,

  // Reverb (200–299).
  verbPredelay = 200,
  verbDecay = 201,
  verbSize = 202,
  verbDiffusion = 203,
  verbHighCut = 204,
  verbLowCut = 205,
  verbModulation = 206,
  verbWidth = 207,
  verbMix = 208,

  // Delay (300–399).
  /// 1 for a time in notes at the song's tempo, 0 for milliseconds.
  dlySync = 300,
  dlyTime = 301,
  /// 0–10: 1/32, 1/16T, 1/16, 1/16., 1/8T, 1/8, 1/8., 1/4T, 1/4, 1/4., 1/2.
  dlyNote = 302,
  dlyFeedback = 303,
  dlyPingPong = 304,
  dlyLowCut = 305,
  dlyHighCut = 306,
  dlyFlutter = 307,
  dlyDrive = 308,
  dlyMix = 309,

  // Retro Synth (400–499).
  /// Waves are 0–3: saw, pulse, triangle, sine.
  synOsc1Wave = 400,
  synOsc2Wave = 401,
  synOsc2Semitones = 402,
  synOsc2Detune = 403,
  /// 0 is all oscillator 1, 100 all oscillator 2.
  synOscMix = 404,
  /// Oscillator 1's shape (5–95 %): the pulse's width, or how far the other waves skew.
  synPulseWidth = 405,
  synNoise = 406,
  synCutoff = 407,
  synResonance = 408,
  /// −100–100: how far (up to six octaves) the filter envelope opens the cutoff.
  synFilterEnv = 409,
  synKeyTrack = 410,
  synFilterAttack = 411,
  synFilterDecay = 412,
  synFilterSustain = 413,
  synFilterRelease = 414,
  synAmpAttack = 415,
  synAmpDecay = 416,
  synAmpSustain = 417,
  synAmpRelease = 418,
  synLfoRate = 419,
  /// 0–2: triangle, square, random.
  synLfoWave = 420,
  /// Vibrato depth in cents.
  synLfoPitch = 421,
  synLfoFilter = 422,
  synLfoPulse = 423,
  synGlide = 424,
  synVelocity = 425,
  /// 0 polyphonic, 1 mono (legato).
  synMode = 426,
  synBendRange = 427,
  synGain = 428,
  /// Oscillator 2's shape, as oscillator 1's.
  synOsc2Shape = 429,
  /// 0 normal, 1 synced to oscillator 1, 2 ring-modulated by it.
  synOsc2Mode = 430,
  /// How much oscillator 2 frequency-modulates oscillator 1.
  synFM = 431,
  /// A square an octave below oscillator 1.
  synSubLevel = 432,
  /// 1–7 stacked voices per note.
  synUnison = 433,
  /// How far apart the stacked voices are tuned, in cents.
  synUnisonDetune = 434,
  /// How widely they're spread across the stereo field.
  synUnisonSpread = 435,

  // Drum Machine (500–599): the kit's volume and drive, then twelve pads of five fields
  // each, pad p's field f at drmFirstPad + OngakuDrumPadStride * p + f.
  drmVolume = 500,
  drmDrive = 501,
  drmFirstPad = 510,

  // Sampler (600–699). The markers are percentages of the sample's length.
  splStart = 600,
  splEnd = 601,
  splLoopStart = 602,
  splLoopEnd = 603,
  /// 0 Classic (plays while the key is held), 1 One Shot (plays to the end).
  splPlayMode = 604,
  /// 0 off, 1 forward, 2 alternate (back and forth).
  splLoop = 605,
  /// Milliseconds.
  splCrossfade = 606,
  splReverse = 607,
  /// The note the sample plays at its own pitch.
  splRoot = 608,
  splTranspose = 609,
  splTune = 610,
  /// Whether the pitch follows the keys (off plays every key at the sample's pitch).
  splFollowKeys = 611,
  splGlide = 612,
  /// 0 polyphonic, 1 mono (legato).
  splVoices = 613,
  splBendRange = 614,
  splFilterOn = 615,
  splCutoff = 616,
  splResonance = 617,
  splFilterEnv = 618,
  splKeyTrack = 619,
  splFilterAttack = 620,
  splFilterDecay = 621,
  splFilterSustain = 622,
  splFilterRelease = 623,
  splAmpAttack = 624,
  splAmpDecay = 625,
  splAmpSustain = 626,
  splAmpRelease = 627,
  splVelocity = 628,
  splLfoRate = 629,
  /// 0–2: triangle, square, random.
  splLfoWave = 630,
  splLfoPitch = 631,
  splLfoFilter = 632,
  /// Tremolo depth.
  splLfoAmp = 633,
  splGain = 634,

  // Noise Gate (700–799).
  gateThreshold = 700,
  /// How far the gate closes, in dB (−100 is silence).
  gateReduction = 701,
  gateAttack = 702,
  gateHold = 703,
  gateRelease = 704,
  /// How far below the threshold the level must fall before the gate closes again (dB).
  gateHysteresis = 705,
  /// The detector's high-pass: keeps low rumble (or a kick's spill) from opening the gate.
  gateKeyLowCut = 706,

  // Transient Shaper (800–899), percentages from −100 to 100.
  trnAttack = 800,
  trnSustain = 801,
  trnOutput = 802,
  trnMix = 803,

  // Maximizer (900–999): a look-ahead limiter with loudness metering.
  maxGain = 900,
  /// The output ceiling, in dBFS.
  maxCeiling = 901,
  maxRelease = 902,
  /// 1 catches peaks between samples (true peak), 0 sample peaks only.
  maxTruePeak = 903,

  // De-Esser (1000–1099).
  desFrequency = 1000,
  desThreshold = 1001,
  /// The most it turns the sibilance down (dB).
  desRange = 1002,
  /// 1 plays only what's being removed, for finding the frequency.
  desListen = 1003,

  // Saturation (1100–1199).
  satDrive = 1100,
  /// 0 tape, 1 tube, 2 transistor (hard clip).
  satType = 1101,
  /// −100 darker … 100 brighter.
  satTone = 1102,
  satOutput = 1103,
  satMix = 1104,

  // Doubler (1200–1299).
  dblDelay = 1200,
  dblDetune = 1201,
  /// How much the timing and tuning drift, as a second player's would.
  dblDrift = 1202,
  dblWidth = 1203,
  dblMix = 1204,

  // Convolution Reverb (1300–1399): the impulse response is built from Size, Decay,
  // Damping and Predelay (or loaded from a file), then played by convolution.
  cnvPredelay = 1300,
  cnvDecay = 1301,
  cnvSize = 1302,
  cnvDamping = 1303,
  cnvWidth = 1304,
  cnvLowCut = 1305,
  cnvHighCut = 1306,
  cnvMix = 1307,

  // Vocal Strip (1400–1499).
  voxLowCut = 1400,
  voxDeEss = 1401,
  voxCompress = 1402,
  voxBody = 1403,
  voxPresence = 1404,
  voxAir = 1405,
  voxOutput = 1406,

  // Session Drummer (1500–1599); its kit uses the Drum Machine's addresses (500–).
  sdrVolume = 1500,
  sdrPlaysKit = 1501,
  sdrSendsMIDI = 1502,
  sdrPreview = 1503,
  /// 0: Ongaku's Drum Machine; 1–6: Apple's General MIDI kits (Standard, Power, Electronic,
  /// TR-808, Brush, Orchestra).
  sdrKit = 1504,
  sdrParameterCount = 5,

  // Mastering (1600–1699): the controls, then the settings the listening pass writes for
  // the song (the EQ bands, the compressor and the measured loudness).
  /// 0 Clean, 1 Valve, 2 Punch, 3 Transparent.
  mstCharacter = 1600,
  /// The loudness to finish at (LUFS).
  mstLoudness = 1601,
  /// 1 plays the input instead, as late and as loud as the processed sound.
  mstCompare = 1602,
  /// How much of the EQ bands' gains is applied (%).
  mstEQAmount = 1603,
  /// How firmly the compressor works: 50 % as set, less gentler, more firmer.
  mstDynamics = 1604,
  /// 0 leaves the stereo image alone; 100 % turns the side up by half above about 300 Hz.
  mstWidth = 1605,
  /// The side (the difference between left and right) is removed below this, so the lows
  /// are mono; under 60 Hz is off.
  mstLowEndMono = 1606,
  /// The highest the output's true peak can go (dBTP).
  mstCeiling = 1607,
  /// EQ bands in dB: a low shelf (100 Hz), bells at 250 Hz, 3 kHz and 7 kHz, a high shelf
  /// (10 kHz).
  mstLowShelf = 1610,
  mstLowMid = 1611,
  mstPresence = 1612,
  mstAir = 1613,
  mstHighShelf = 1614,
  mstThreshold = 1620,
  mstRatio = 1621,
  mstAttack = 1622,
  mstRelease = 1623,
  /// The input's integrated loudness as analysed (LUFS); −70 until it has been.
  mstMeasuredLoudness = 1640,
  /// On while Mastering listens to the song; turned off, it sets the song's settings from
  /// what it heard (see MasteringListening.swift). Reads as off once listening has stopped.
  mstListen = 1650,
};

/// The drum machine's pads: kick, snare, clap, rim, closed hat, open hat, low, mid and high
/// toms, cowbell, crash and shaker.
static const int OngakuDrumPadCount = 12;
static const int OngakuDrumPadStride = 5;

typedef NS_ENUM(int, OngakuDrumField) {
  /// Semitones.
  OngakuDrumFieldTune = 0,
  /// Percent of the drum's natural length.
  OngakuDrumFieldDecay = 1,
  /// 0–100: what it changes depends on the drum (the kick's click, the snare's snap…).
  OngakuDrumFieldTone = 2,
  /// Decibels.
  OngakuDrumFieldLevel = 3,
  /// −100 (left) to 100 (right).
  OngakuDrumFieldPan = 4,
};

/// What the meters (see `setMeters`) hold.
typedef NS_ENUM(int, OngakuMeter) {
  OngakuMeterInputPeak = 0,
  OngakuMeterOutputPeak = 1,
  OngakuMeterGainReduction = 2,
  /// The host's tempo, as the Delay (or the Session Drummer) last heard it.
  OngakuMeterTempo = 3,
  /// The Session Drummer: where its part is (quarter notes in; negative when stopped), and
  /// the host's meter (beats per bar × 100 + beat unit).
  OngakuMeterPartPosition = 0,
  OngakuMeterSignature = 2,
  /// The drum machine's pads, how loud each is sounding (0–1), from here on.
  OngakuMeterFirstPad = 4,
  /// The sampler's playheads, where each sounding voice is (0–1 of the sample, or −1),
  /// from here on.
  OngakuMeterFirstPlayhead = 4,
  /// The Maximizer's loudness (LUFS): momentary, short-term and integrated; and the true
  /// peak (dBTP).
  OngakuMeterMomentary = 4,
  OngakuMeterShortTerm = 5,
  OngakuMeterIntegrated = 6,
  OngakuMeterTruePeak = 7,
  /// The Noise Gate's state: 1 open, 0 closed.
  OngakuMeterGateOpen = 4,
  /// Mastering: the loudness in and out (short-term, LUFS), what the limiter takes (dB) and
  /// the make-up gain (dB); the output's true peak (dBTP) is in `OngakuMeterTruePeak`, and
  /// the compressor's reduction in `OngakuMeterGainReduction`.
  OngakuMeterInputLoudness = 4,
  OngakuMeterOutputLoudness = 5,
  OngakuMeterLimiting = 6,
  OngakuMeterMakeUp = 8,
  OngakuMeterCount = 16,
};

/// The Channel EQ's bands, from the low cut up to the high cut.
typedef NS_ENUM(int, OngakuEQBand) {
  OngakuEQBandLowCut = 0,
  OngakuEQBandLowShelf = 1,
  OngakuEQBandFirstBell = 2,
  OngakuEQBandHighShelf = 6,
  OngakuEQBandHighCut = 7,
  OngakuEQBandCount = 8,
};

typedef NS_ENUM(int, OngakuEQBandField) {
  OngakuEQBandFieldOn = 0,
  OngakuEQBandFieldFrequency = 1,
  OngakuEQBandFieldGain = 2,
  OngakuEQBandFieldQ = 3,
  /// The cuts' slope: 0–5 for 6, 12, 18, 24, 36 or 48 dB per octave.
  OngakuEQBandFieldSlope = 4,
};

/// How far apart the bands' addresses are.
static const int OngakuEQBandStride = 10;
