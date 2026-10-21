# Super Nt / Nt Mini hardware research (web, 21 Oct 2026)

Each claim is tagged with its evidence level:

- **[photo]**: read off a public board photo, with the URL given.
- **[stated]**: said by Analogue or kevtris.
- **[ours]**: our own analysis of files we have.
- **[forum]**: a third-party claim.
- **[guess]**: inference or speculation.

Chip markings were read from crops of the photos below. Where a marking is only partly legible, the
entry says so.

## Board photos (Super Nt, PCB "P/N: 6510A V2.10 092917")

These are 2018 launch units. All four high-resolution shots come from one tweet:
https://x.com/fpgashibe/status/963872082290409474 (14 Feb 2018, "Inside the Analogue Super NT").

| Photo | Use it for |
|---|---|
| https://pbs.twimg.com/media/DWBcLv9W4AAeLkJ.jpg?name=orig (3200×2400, top, straight on; also posted at https://i.redd.it/8q1ukthpf1d51.jpg in https://www.reddit.com/r/AnalogueInc/comments/hxqhoi/analogue_super_nt_motherboard/) | FPGA, SDRAMs, PIC32, PIC16, CD4013, PCM1808 |
| https://pbs.twimg.com/media/DWBchQoXcAMoIrH.jpg?name=orig (3200×2400, top, close and angled) | AD9889B, U3, U15 oscillator, U22 flash |
| https://pbs.twimg.com/media/DWBcM1uXcAAy4ik.jpg?name=orig (3200×2400, **bottom**) | the 8 level shifters behind the cart slot, the third SDRAM |
| https://pbs.twimg.com/media/DWBcXN7WsAIY5ZK.jpg?name=orig (3044×2400, top, angled) | overview |
| https://cdn.vox-cdn.com/uploads/chorus_asset/file/10174149/super_nt_guts.jpg (2839×1920, top, inside the clear case; linked from the Atari-Forum thread below) | FPGA marking, a second sample of the same board revision |

## Parts list (top side unless noted)

| Ref | Marking | Part / function | Evidence |
|---|---|---|---|
| U1 | `5CEBA4F23C8N  F BABAU1731A  TAIWAN` | Altera Cyclone V E **5CEBA4**, **F23 = 484-pin FBGA**, C8 speed grade, date code 2017 wk 31. So the F23 pin names in our notes are correct. | [photo] |
| U2 | `AD9889B BCPZ-165 … SINGAPORE` | **Analog Devices AD9889B** (AD9889BBCPZ-165) HDMI 1.3 transmitter, 64-lead LFCSP. Configured over I2C; takes parallel video plus I2S/SPDIF audio. ADI now points new designs to the ADV7513 ([changeover guide](https://www-cce.cldnet.analog.com/media/en/technical-documentation/evaluation-documentation/AD9889B-to-ADV7513-Changeover-Guide.pdf)). | [photo] |
| U3 | `4786 / 23 06 / TSD7271` (QFN between U2 and the HDMI jack) | not identified (HDMI ESD/DDC/HPD companion?) | [photo], identity [guess] |
| U5 (top) + U16 (bottom) | `ISSI IS42S81600F-6TL` | 2 × 16M×8 **SDR SDRAM** (128 Mbit each, 166 MHz, TSOP-II 54) | [photo] |
| U4 | `ALLIANCE AS4C8M16SA-6TCN` | 8M×16 **SDR SDRAM** (128 Mbit, 166 MHz) | [photo] |
| U21 | `PIC32MX 470F512H -I/PT` | **Microchip PIC32MX470F512H-I/PT**: 64-TQFP, 512 KB flash, 128 KB RAM, USB OTG, PMP parallel master port | [photo] |
| U22 | SOIC-8, `?25LP128 …` (only partly legible) | probably **ISSI IS25LP128**, 128 Mbit (16 MB) SPI NOR, i.e. firmware/bitstream storage | [photo], part [guess] |
| U24 | `PIC16F630 -E/SL` | Microchip PIC16F630 (14-SOIC). Probably the SNES **CIC lock** emulation: the open SuperCIC lock firmware targets exactly this chip ([dbwbp](https://dbwbp.com/index.php/projects/10-electronic-projects/24-snes-cart-region-free-modification-replacing-cic-lockout-chip-with-supercic)). | marking [photo], role [guess] |
| U14 | `PCM1808 BB 78K` | **TI/Burr-Brown PCM1808**, 24-bit stereo audio **ADC** (I2S or left-justified output, master or slave; [ti.com](https://www.ti.com/product/PCM1808)). Digitises the cartridge-slot audio input (Super Game Boy, MSU-1). | [photo]; cart-audio role per [YouTube](https://www.youtube.com/watch?v=huuc2Uxd1DE) description |
| U28 | `TI CD4013BM` | dual D flip-flop, next to SW1. Possibly the power/reset button latch. | [photo], role [guess] |
| U6–U13 (**bottom**, directly behind the cart slot) | TI logo, `NH245` | 8 × **SN74LVC8T245PW** (8-bit dual-supply translating transceivers, 1.65–5.5 V on each side). TI confirms that `NH245` is this part's marking ([TI E2E](https://e2e.ti.com/support/logic-group/logic/f/logic-forum/990744/sn74lvc8t245-looking-for-nh245-variant-of-this-part)). | [photo] + TI |
| U15 | `AOHQX`, 4-pad SMD can next to the FPGA | crystal oscillator, most likely the FPGA reference clock (74.25 MHz per the bitstream) | [photo], frequency [guess] |
| X1 | resonator/crystal next to the PIC32 | PIC32 clock | [photo] |
| J1 / J2 / J3 | HDMI, SNES cart edge, full-size SD socket | | [photo] |
| J8 | unpopulated 2×5 0.1" header next to the SDRAMs | probably **FPGA JTAG** (the Altera USB-Blaster header is 2×5). Frederir on Atari-Forum: "One not populated HE10 connector is certainly the JTAG for the FPGA". | [photo]; role [forum]/[guess] |
| J9 | unpopulated 3-pin | unknown (UART?) | [photo] |
| J10 | micro-USB | power input | [photo] |
| J4, J7 | 4-pin white connectors | unknown | [photo] |
| J5, J6 | controller ports | with Q1–Q7, D1–D7, R36–R45 around them | [photo] |

Things that are **not** on the board:

- No audio DAC. The console is HDMI-only ([stated]: Analogue's Christopher Taber, "Super Nt is HDMI
  only… No analog out", [Retronauts](https://retronauts.com/article/622/the-ultimate-nes-gets-a-super-follow-up-mdash-and-this-ones-priced-to-sell)).
  Audio leaves as I2S into the AD9889B.
- No DDR memory.
- No second FPGA or CPLD. kevtris's 2015 design notes planned a MAX 10 helper (see "Firmware and
  core loading" below); this board doesn't have one.

### Important correction for spc-core.md: the RAM is SDR SDRAM, not DDR

All three RAM chips are **single-data-rate SDRAM** (IS42S81600F and AS4C8M16SA). The Cyclone V hard
memory controller only supports DDR2/DDR3/LPDDR2, so the "top bank, rows A–K → hard memory controller
→ DDR" reading in `spc-core.md` needs rechecking:

- [guess] Those pins are probably a soft SDRAM controller whose I/O registers happen to sit in the
  HMC-capable bank, or the `HMC.…:IOINT` routing is just how mistral names the I/O path there.
- [guess] Likely layout: the two ×8 ISSI parts sit back to back (U5 top, U16 bottom) on shared
  address/control, forming one 16-bit, 32 MB bus. The Alliance ×16 is a second, independent 16-bit,
  16 MB bus.
- [forum] Sorgelig (MiSTer) on Atari-Forum, after seeing only the top two chips: "Obviously one is for
  HDMI scaler" ([thread](https://www.atari-forum.com/viewtopic.php?t=33187)).
- Total: 48 MB of SDRAM across two buses (counting from the photos).

## Board revisions

- **2018 launch run: PCB 6510A V2.10, dated 29 Sep 2017** (photos above) [photo].
- **2023 final run: changed components.**
  - [forum] "These 2023 Super Nts have component changes due to previous components now becoming end
    of life. As a consequence, a 'new' Super Nt owner cannot downgrade to firmware released before
    2023." The cartridge-audio filtering also differs. Source: the description of
    https://www.youtube.com/watch?v=huuc2Uxd1DE (17 Jul 2023).
  - JB7.2's changelog says "Now supports all hardware versions"
    ([analoguejb](https://github.com/analoguejb/Analogue-Super-Nt-JB)).
  - **No photo of a 2023 board was found**, so we don't know which parts changed.
  - [guess] The AD9889B (superseded by the ADV7513) and the PCM1808 audio path are candidates. **A
    2023 unit could have a different HDMI chip, and so different I/O, from the photos.** Check our
    unit's revision (purchase date or firmware level) before trusting pin assignments.
- **Super Nt+, announced Oct 2026**: new hardware.
  - Analogue says: "Altera Cyclone V FPGA", Bluetooth/2.4 GHz, USB-C, and "Super Nt+ does not support
    openFPGA" ([analogue.co/super-nt](https://www.analogue.co/super-nt)).

## Nt Mini / Nt Mini Noir

- [stated] Taber: "The PCB in the Super Nt is virtually the same PCB used in the Nt mini; literally
  everything is the same, minus analog AV… Same Altera FPGA chip"
  ([Retronauts, Oct 2017](https://retronauts.com/article/622/the-ultimate-nes-gets-a-super-follow-up-mdash-and-this-ones-priced-to-sell)).
- [stated] kevtris on the Nt mini: "I am just the guy that did the PCB/code"
  ([AtariAge, Mar 2017](https://forums.atariage.com/topic/263325-analogue-nt-mini-hardware/)).
- [forum] Blog claim: "The Super Nt uses a Cyclone V FPGA like the Nt Mini, but is using the A4
  instead of the A2" ([Nerdly Pleasures](http://nerdlypleasures.blogspot.com/2017/10/the-analogue-super-nt-day-after-preview.html)).
  Unverified.
- No Nt Mini or Noir photo with readable chips was found.
  - CNET's gallery shows only the bottom of the Nt Mini board, with no ICs on it:
    https://www.cnet.com/wp-content/uploads/sites/2/04bd0906-946c-436a-93f1-81be792c1985.jpg
  - For the Noir, a retailer note says the "upgraded FPGA" is unnamed
    ([RetroRGB](https://retrorgb.com/analogue-delays-nt-mini-v2-details-new-features.html)).

## Firmware and core loading (question 2)

### What kevtris said (2015 design thread, before the Analogue products)

These posts are about his "Z3K/Zimba 3000" concept, which became the Nt mini. Treat them as design
intent, not as a description of the shipped product.

- "There's probably going to be a PIC32 but it will just run 'BIOS' type code that does the menus, some
  SD card work, file system and USB. Any other CPU will be synthesized inside the FPGA. On the HDMI NES
  adapter there's a synthesized 65C02 core that is doing all the menu/system upkeep stuff and my other
  cores probably won't be an exception to this, and most will have 'helper' CPUs (probably the 65C02…)"
  ([AtariAge, 30 Sep 2015](https://forums.atariage.com/topic/242970-fpga-based-videogame-system/?do=findComment&comment=3333989)).
- "There's probably going to be some kind of standard interface for all the cores though… Ideally I
  want it easy enough so other people can make cores for it… The file extension determines what core
  is loaded… a text file list that sits on the card, which maps file extension to core filename… It
  also contains an int that is sent to the core"
  ([AtariAge, 1 Oct 2015](https://forums.atariage.com/topic/242970-fpga-based-videogame-system/page/11/)).
  Same page: the FPGA would be "a cyclone V 49K part, specifically the 5CEBA4F17C8N". The shipped
  Super Nt has the F23 package instead.
- He planned "a smaller helper part like a MAX 10 to keep the lights on during reconfiguration as well
  as handling the scaling duty and SD card things for maximum loading speed. I don't want the HDMI to
  blip out when it reloads" (same page). **The shipped boards don't do this**: HDMI drops while a
  core loads (next section).
- "I am going to have the bit stream loading all automatic and behind the scenes… The PIC32 will
  probably be updateable via SD card also"
  ([AtariAge, 22 Oct 2015](https://forums.atariage.com/topic/242970-fpga-based-videogame-system/?do=findComment&comment=3350497)).

### Shipped behaviour

- [stated] kevtris on the Nt mini: "the nt mini stopped sending HDMI signals while it reconfigures its
  FPGA… the front LED will blink red while it loads the new configuration… wait 19 seconds or so after
  selecting a core" ([nesdev, May 2017](https://forums.nesdev.org/viewtopic.php?t=15886)).
- Load times from the jailbreak READMEs:
  - Nt mini v1 (JB2.0 README): "The loading takes approximately 19 seconds… the monitor will show no
    signal, since the FPGA is being reconfigured."
  - Nt Mini Noir (JB6.7 README): "approximately 4 seconds".
  - [ours] With 2.63 MB cores, that is about 140 KB/s on the v1 and about 650 KB/s on the Noir. The v1
    figure fits an MCU bit-banging passive-serial configuration from SD. The Noir figure fits a faster
    path (parallel FPP or a better SD driver). [guess] on the mechanism.
- Core files are kept on the SD card in `/SYSTEM/CORES/`. A firmware `.bin` in the SD root is flashed
  on boot and takes about 3 minutes ([JB READMEs](https://github.com/SmokeMonsterPacks/Nt-Mini-Noir-Jailbreak)).

### Core file formats [ours]

We compared files from our JB7.2 zip, kevtris's Nt mini JB2.0 zip
(http://blog.kevtris.org/blogfiles/ntm_firmware_verJB2.0.zip) and the Noir JB6.7 zip
(https://github.com/analoguejb/Analogue-Nt-Mini-Noir-JB/releases/download/v6.7/ntmv2_firmware_verJB6.7.zip).

| Product | Core file | Size | Format |
|---|---|---|---|
| Super Nt JB7.2 | `SYSTEM/CORES/spc.cor` | 2,632,660 bytes | raw bit-reversed RBF, no header |
| Nt mini v1 JB2.0 (2017) | `SYSTEM/CORES/*.cor` (a2600, gb, …) | 2,632,660 bytes | identical format: 128 bytes of 0xFF, then `56 56 56 56 6c 2f …` |
| Nt Mini Noir JB6.7 | `SYSTEM/CORES/*.NT2` | 2,632,676 bytes | **16-byte header** + the same 2,632,660-byte RBF body |

- The NT2 header differs per file and looks random:
  - SPC.NT2: `ff6c36b684278496f4f5b6604f0154ff`
  - GB.NT2: `6ce56b10bb54f379e006c4a6de4e0476`
  - It is not the MD5, SHA-1, SHA-256, SHA-512, BLAKE2, SHA3 or CRC32 of the body (tested raw and
    bit-reversed).
  - [guess] It is probably a keyed MAC, a signature or encrypted metadata, so the Noir loader may
    authenticate cores. The Super Nt and Nt mini v1 `.cor` files carry nothing of the kind.
- All three products produce the same bitstream size. That fits the same die, though it can't by
  itself tell an A2 from an A4.
- The **firmware images are encrypted** (8.000 bits/byte entropy, no strings):
  - `snt_firmware_verJB7.2.bin` and `ntmv2_firmware_verJB6.7.bin` are both exactly 8,747,008 bytes.
  - `ntm_firmware_verJB2.0.bin` is 4,536,320 bytes.
  - So the PIC32 code (and probably the built-in SNES core) can't be read from the update file.
  - The jailbreak was evidently built with Analogue's own signing/encryption, not through an exploit.
    The Nt mini v1 JB is hosted on kevtris's blog. Who made the Super Nt JB is not officially stated;
    Nintendo Life commenters disagree
    ([Nintendo Life](https://www.nintendolife.com/news/2018/02/analogues_super_nt_gets_its_first_jailbroken_firmware)).

### Third-party / homebrew cores

- **No report found of anyone running a third-party core on a Super Nt, Nt mini or Noir.**
- [forum] Sorgelig and Newsdee on Atari-Forum (Feb 2018): everything is closed source. Porting MiST
  might be possible; MiSTer is not, because it needs the HPS.
- [stated] Analogue: Super Nt+ "does not support openFPGA" ([analogue.co](https://www.analogue.co/super-nt)).
- [guess] On the Super Nt the evidence points to replacing `spc.cor` being enough to get our own
  bitstream configured:
  - The `.cor` is a plain RBF with no header (our `out/spc-colortest.cor` experiment tests exactly
    this).
  - kevtris's stated design has the PIC32 do the bitstream loading.
  - **Whether the PIC32 checks anything before configuring is still unknown.** Nobody has published
    this.

## HDMI transmitter configuration (question 3)

- Fact (datasheet): the AD9889B does nothing until it is set up over I2C (power-up, input format, AVI
  infoframes, audio N/CTS). Something on the board must write its registers.
- No public statement was found on whether the PIC32 or the FPGA core does this.
- Evidence so far, all circumstantial:
  - Our bitstream analysis found no HDMI init table in the SPC core. B11 is its only I2C-like pin
    (spc-core.md).
  - kevtris's design note gives the PIC32 the housekeeping role.
  - The 2015 plan to keep HDMI alive across reconfiguration was dropped.
- [guess] So the PIC32 most likely owns the AD9889B's I2C bus, and a core only has to drive RGB, sync,
  DE, the pixel clock and I2S.
- Counterpoint: menus change resolution (480p, 720p, 1080p, "120Hz video" bug in the JB7.2 notes),
  and the AD9889B needs some register changes for that (VIC, pixel repetition, N/CTS). So the core
  would have to ask the PIC32 for them, perhaps over the parallel link.
- Check: trace the AD9889B SDA/SCL pins on the close-up photo (`DWBchQoXcAMoIrH`), or probe them on
  a unit.

## Cartridge slot and controller ports (question 4)

- [photo] **The cart bus goes through 8 × SN74LVC8T245** on the underside, right behind the slot
  (U6–U13). That gives 64 translated lines with a direction pin per 8 bits. **So the FPGA is not
  connected directly to the 5 V cart bus.**
  - The SNES slot carries about 24 address, 8 data and 8 PA lines plus control, clock and
    expansion-chip pins. That fits 8 chips well.
  - [guess] Most chips are fixed outbound (address, PA, control), with one bidirectional byte for D0–7.
  - Our "4A 8-bit bus with one shared OE" bitstream group fits a D0–7 byte whose DIR pin is driven by
    the FPGA.
- **Implication for our cores:** a core must drive the LVC8T245 DIR/OE lines to a safe state.
  - With no cartridge inserted, leaving them as inputs is probably safest.
  - The direction-control pins need identifying before we drive anything toward the slot.
- [photo] Cart audio enters through the PCM1808 ADC (I2S into the FPGA, or into the PIC32? unknown).
- [photo] CIC: a PIC16F630 sits near the PIC32. It is most likely a CIC lock that the FPGA/PIC32 can
  reset or enable [guess].
- [photo] Controller ports J5/J6 have discrete transistors (Q1–Q7), diodes (D1–D7) and resistors
  (R36–R45) near them, and no logic ICs. [guess] They are probably transistor level shifting and
  protection for latch/clock out and per-port data in. Not traced.
- [forum] Sorgelig: "of course it's connected to FPGA" (the cartridge, as opposed to the PIC32)
  ([Atari-Forum](https://www.atari-forum.com/viewtopic.php?t=33187)). The photos agree: the shifters
  sit between the slot and the FPGA side of the board.

## Searched without results

- Teardowns on iFixit, a Mega Sg board photo, a Nt Mini/Noir top-side photo.
- kevtris statements on the AD9889B, I2C, SDRAM or core signing for the Super Nt specifically. He
  says he is contractually limited in what he can comment on
  ([AtariAge](https://forums.atariage.com/topic/263325-analogue-nt-mini-hardware/)).
- Any documentation of the PIC32 ↔ FPGA protocol.
