# Building the bitstream with Vivado (cloud / Linux)

Vivado has **no macOS build**, and your Mac is Apple Silicon (a local x86 Linux VM
would only emulate, slowly). So the workflow is split:

```
  Linux box (cloud) ──build──▶ spi_inject_top.bit ──scp──▶ Mac ──openFPGALoader──▶ Cmod A7
```

Synthesis runs on a Linux machine; **programming stays on the Mac** with
openFPGALoader (already installed — `make prog`). The design is tiny, so once Vivado
is installed a build takes a couple of minutes.

---

## Cheap VPS (Hetzner): ~€7/month, setup

The cheapest option that actually runs Vivado. A true $5/mo VPS is 1 GB RAM and
can't; the floor is 8 GB. **Hetzner CX32** — 4 vCPU, 8 GB RAM, 80 GB disk — is
~€6.80/mo (hourly billing, so you can delete it between builds and pay only for the
hours used). CX-line is EU-located; if you want US, use `CPX31` (AMD, ~€13/mo).

Everything is plain SSH/scp — no provider CLI needed.

**If you're seeing ~€40/mo or can't find CX32**, you're in the wrong place:
- Use **Hetzner *Cloud*** at **console.hetzner.cloud** — *not* the dedicated-server
  section on hetzner.com (that's the €40+ product).
- **CX32 only exists in EU locations** (Falkenstein / Nuremberg / Helsinki). If you
  picked a US location you won't see it; pick EU, or use **CPX31** (AMD, 8 GB, ~€13)
  which is available in the US.
- In the type picker, skip **CAX** (that's ARM — Vivado is x86-only) and **CCX**
  (dedicated vCPU, the expensive line). You want a shared-vCPU **x86** type.
- Not Hetzner? The other cheap 8 GB x86 hosts are **Contabo** (~€6) and **Netcup**
  (~€8). Avoid DigitalOcean/Vultr/Linode — their 8 GB tiers are ~$40–48/mo.

### 1. Create the server
In the Hetzner Cloud console (console.hetzner.cloud): new project → Add Server →
- Location: an **EU** location (to get the cheap CX line)
- Image: **Ubuntu 22.04** (avoid 24.04/26.04 — they dropped libtinfo5, which Vivado needs)
- Type: **CX32** (8 GB / 80 GB), or **CPX31** if only US locations are offered
- SSH key: add your `~/.ssh/id_*.pub` (Add SSH key)

Tight on budget? Our design is tiny, so a **4 GB** x86 VPS (CX22, ~€4) will likely
build it if you add swap first:
```
sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
```

Note the server's IP. Then from your Mac:
```
ssh root@<SERVER_IP>
```

### 2. Prerequisites (on the server)
On Ubuntu 22.04, `libtinfo5` is in the "universe" repo — enable it first:
```
apt update
apt install -y software-properties-common
add-apt-repository -y universe && apt update
apt install -y libtinfo5 libncurses5 libx11-6 libxext6 libxrender1 unzip git
```
If `libtinfo5` won't install (24.04+ dropped it), fetch the .deb directly:
```
wget http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2_amd64.deb
apt install -y ./libtinfo5_6.3-2_amd64.deb
```

### 3. Get the Vivado installer up
Download **"Vivado ML Standard — Linux Self Extracting Web Installer"** from the AMD
site (free account) in your Mac browser (~300 MB), then:
```
# --- on your Mac ---
scp ~/Downloads/FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin root@<SERVER_IP>:~
```

### 4. Install Vivado headless, trimmed to Artix-7
```
# --- on the server ---
chmod +x FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin
./FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin --keep --noexec --target ~/xsetup
cd ~/xsetup
./xsetup -b AuthTokenGen          # enter your AMD login once; caches a download token
./xsetup -b ConfigGen             # choose: 1) Vivado -> Vivado ML Standard
```
`ConfigGen` writes `~/.Xilinx/install_config.txt`. Open it and trim ~100 GB → ~30–40 GB:
under `Modules`, set **every device family except `Artix-7` to `:0`**, and turn off
Vitis/DocNav if listed. (This also matters here because the 80 GB disk is tight —
trimming keeps the install comfortably under it.) Then:
```
./xsetup --agree XilinxEULA,3rdPartyEULA --batch Install --config ~/.Xilinx/install_config.txt
```
(Flags shift between versions — if one is rejected, check `./xsetup --help`.)

**Disk too small? (`ERROR - not enough disk space`)** Recent Vivado (2024+ / 2026.x)
is one giant unified install that needs **well over 75 GB even trimmed to one
device**. On a 75 GB disk, use an **older Vivado with the free WebPACK edition**
instead — e.g. **2020.2 WebPACK**, which fully supports the XC7A35T and installs in
~20–30 GB. Get it from the AMD **Vivado Archive**, and in `ConfigGen` pick
**Vivado HL WebPACK** (the small free edition newer installers no longer offer).
Alternatively, provision 150 GB (Contabo VPS 10 offers 150 GB SSD at the same price)
and keep the latest Vivado.

### 5. Build the bitstream
```
# --- on the server ---
source /tools/Xilinx/Vivado/*/settings64.sh
git clone <your-repo-url> hardfuzz && cd hardfuzz   # or scp rtl/ constraints/ scripts/ up
vivado -mode batch -source scripts/build.tcl -tclargs xc7a35tcpg236-1 spi_inject_top
grep -i "timing constraints" build/vivado/timing.rpt
```

### 6. Copy the .bit back and program from the Mac
```
# --- on your Mac, in the repo root ---
mkdir -p build/vivado
scp root@<SERVER_IP>:~/hardfuzz/build/vivado/spi_inject_top.bit build/vivado/
make prog                         # openFPGALoader -> Cmod A7 (SRAM)
```

### 7. Stop paying between builds
Hetzner bills hourly. To fully stop charges you **delete** the server — but then you
lose the Vivado install. Two options:
- **Occasional builds:** take a **snapshot** (~€0.01/GB/mo, so a trimmed install is
  well under €1/mo), delete the server, and recreate from the snapshot next time.
- **Frequent builds:** just leave the CX32 running (~€6.80/mo) — simplest.

---

## Contabo: alternative cheap 8 GB (if Hetzner won't cooperate)

Contabo's **Cloud VPS 10** — 3 vCPU, 8 GB RAM, 75 GB NVMe (x86 AMD EPYC) — is
~€5–6/mo and runs Vivado fine. What's different from Hetzner:

- Order at **contabo.com → Cloud VPS** (not "Cloud VDS"). Pick the tier with **8 GB
  RAM**; 75 GB NVMe fits a trimmed Artix-7 install. Choose **Ubuntu 22.04** (not
  24.04/26.04 — those dropped libtinfo5) and add your SSH key (or use the root
  password they email).
- **Monthly billing, not hourly** — no stop-to-save like Hetzner. Keep it for the
  project (~€5–6/mo) and cancel when done. A 1-month term may carry a small one-time
  setup fee; fine for a short project.
- Provisioning can take minutes to a couple of hours (new-account review); NVMe plans
  are usually quick.

Once you can `ssh root@<SERVER_IP>`, **everything from step 2 of the Hetzner section
onward is identical** — prerequisites, the trimmed Vivado install, build, and `scp`
the `.bit` back to `make prog`.

---

## Provider-agnostic reference

## 1. Stand up a Linux machine

Any x86-64 Linux box works; a cloud instance is easiest from a Mac. Rough spec:

- Ubuntu 22.04 LTS (install libtinfo5 from the universe repo — see step 2). Avoid
  24.04/26.04, which dropped libtinfo5 and aren't Vivado-supported.
- ≥ 8 GB RAM (target), ~60–80 GB disk for a trimmed Artix-7 install.
- e.g. Hetzner `CX32`, AWS `t3.large`, Azure `D2s_v5`, or any 8 GB x86 VM.

Install Vivado's runtime prerequisites:
```
sudo apt update
sudo apt install -y libtinfo5 libncurses5 libx11-6 libxext6 libxrender1 unzip
```

## 2. Get Vivado (free, no license for Artix-7)

The free **Vivado ML Standard Edition** (formerly WebPACK) covers the XC7A35T/15T with
no license file. From the AMD download page (needs a free AMD account):

- Grab the **"Linux Self Extracting Web Installer"** (`.bin`). Easiest: download it in a
  browser on your Mac while logged in, then copy it to the instance:
  ```
  scp FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin  user@INSTANCE:~/
  ```

Headless install (exact flags vary by version — check `./xsetup --help`):
```
chmod +x FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin
./FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin --keep --noexec --target ./xsetup_dir   # extract
cd xsetup_dir
./xsetup -b ConfigGen              # pick: Vivado -> Vivado ML Standard; save config
# (optional) edit the generated ~/.Xilinx/install_config.txt to select only the
# Artix-7 device family and skip SDK/Vitis — shrinks the install a lot.
./xsetup -a XilinxEULA,3rdPartyEULA -b Install -c ~/.Xilinx/install_config.txt
```

Then source the tools (every shell / build):
```
source /opt/Xilinx/Vivado/<version>/settings64.sh
```

## 3. Build the bitstream

Copy the sources over (git clone your repo, or scp just what's needed):
```
scp -r rtl constraints scripts  user@INSTANCE:~/hardfuzz/
```
On the instance:
```
cd ~/hardfuzz
vivado -mode batch -source scripts/build.tcl -tclargs xc7a35tcpg236-1 spi_inject_top
#   -> build/vivado/spi_inject_top.bit  (+ timing.rpt, util.rpt)
```
For the A7-15T use `xc7a15tcpg236-1`. Skim `build/vivado/timing.rpt` for
"All user specified timing constraints are met."

## 4. Copy back and program from the Mac

```
scp user@INSTANCE:~/hardfuzz/build/vivado/spi_inject_top.bit  build/vivado/
make prog          # openFPGALoader loads it to SRAM (volatile)
# make prog-flash  # or persist to the Cmod's SPI flash
```

## macOS programming note

openFPGALoader talks to the Cmod's FT2232 **JTAG** channel over USB; the **UART**
channel (the serial port `arm.py` uses) is separate and can stay connected. If
`make prog` can't claim the device, unplug/replug the Cmod and make sure no other
program holds the JTAG channel. The UART VCP being open is fine.

## Tip: keep the instance cheap

Install Vivado once on a persistent disk/volume, then **stop** the instance between
sessions so you only pay for storage. A build is a quick `ssh + one command` when you
need a new bitstream.
