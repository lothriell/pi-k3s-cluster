# 01 - Flash Ubuntu Server onto Raspberry Pi CM5 Modules

## What you'll learn

- How Compute Modules differ from regular Raspberry Pis (they need special flashing)
- How to use `rpiboot` to expose the CM5's eMMC as a USB drive
- How to flash Ubuntu Server 24.04 LTS onto all 4 modules
- First-boot setup: password, hostname, SSH

> **Note:** This is the only step in the entire project where you physically
> touch the Pis. After this, everything is done remotely from your Mac.

---

## What you need

| Item | Notes |
|------|-------|
| 4x Raspberry Pi CM5 (16 GB RAM, 32 GB eMMC) | The modules themselves |
| CM5 IO Board (or compatible carrier board) | Needed to access the USB boot pins and USB-C port |
| USB-C cable | To connect the IO board to your Mac |
| Your Mac | To run the flashing tools |

---

## How Compute Modules work (vs a regular Pi)

A regular Raspberry Pi has an SD card slot -- you pop in a card, flash it, done.

A Compute Module (CM5) has **eMMC storage soldered onto the board**. There is no
SD card slot. To flash it, you need to:

1. Put the module into **USB boot mode** (using a jumper or switch on the IO board).
2. Run a tool called **rpiboot** that makes the eMMC appear as a USB drive on your Mac.
3. Flash the image to that USB drive using Raspberry Pi Imager.

It sounds more complicated, but it is really just two extra steps.

---

## Step 1 -- Install rpiboot

`rpiboot` is a tool from the Raspberry Pi Foundation that puts Compute Modules
into USB mass storage mode.

```bash
brew install libusb
```

Then clone and build rpiboot:

```bash
git clone --depth=1 https://github.com/raspberrypi/usbboot.git ~/usbboot
cd ~/usbboot
make
```

You should now have a `rpiboot` binary in `~/usbboot/`:

```bash
~/usbboot/rpiboot --help
```

---

## Step 2 -- Install Raspberry Pi Imager

Download and install [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
from the official site, or install via brew:

```bash
brew install --cask raspberry-pi-imager
```

---

## Step 3 -- Prepare the CM5 IO board

1. **Seat the CM5 module** onto the IO board's connector (line up the two board-to-board connectors, press firmly and evenly).
2. **Set the boot jumper** to disable eMMC boot. On the official CM5 IO board, this is the jumper labeled **nRPIBOOT** (or **BOOT** on some boards) -- fit the jumper to **enable USB boot mode**. Check your IO board documentation if unsure.
3. **Connect the USB-C cable** from the IO board's USB-C slave port to your Mac.
4. **Power on** the IO board (plug in the power supply if your board has a separate power input, or it may be powered over USB-C depending on the board).

---

## Step 4 -- Run rpiboot

```bash
cd ~/usbboot
sudo ./rpiboot
```

You should see output like:

```
Waiting for BCM2712 device to be connected...
Loading embedded: 2712/bootcode5.bin
...
Device located successfully
```

After a few seconds, the CM5's eMMC will appear as a disk on your Mac (similar
to plugging in a USB drive). You can verify with:

```bash
diskutil list
```

Look for a new disk (probably `/dev/disk4` or similar) that matches the 32 GB
size of your eMMC.

### What just happened?

`rpiboot` told the CM5's bootloader to skip its eMMC and instead present itself
as a USB mass storage device. Your Mac now sees the eMMC as an external drive
that you can write to.

---

## Step 5 -- Flash Ubuntu Server 24.04 LTS

1. Open **Raspberry Pi Imager**.
2. Click **Choose Device** and select **Raspberry Pi 5** (CM5 is based on the same SoC).
3. Click **Choose OS** > **Other general-purpose OS** > **Ubuntu** > **Ubuntu Server 24.04 LTS (64-bit)**.
4. Click **Choose Storage** and select the eMMC drive that appeared.
5. Click **Next**.

### Configure settings (important)

Before writing, Imager will ask "Would you like to apply OS customisation
settings?" Click **Edit Settings** and configure:

- **Set hostname:** `rpi-k3s-1` (for the first module; use `rpi-k3s-2`, `rpi-k3s-3`, `rpi-k3s-4` for the rest)
- **Enable SSH:** check "Use password authentication" (you will switch to key-based auth later)
- **Set username and password:** username `myuser`, pick a password you will remember
- **Set locale settings:** your timezone and keyboard layout

Click **Save**, then **Yes** to apply, then **Yes** to confirm writing.

Wait for the write and verification to complete. This takes a few minutes.

---

## Step 6 -- Eject and remove

1. Once Imager says "Write Successful", click **Continue**.
2. Eject the disk: `diskutil eject /dev/diskN` (replace N with the disk number).
3. Disconnect USB-C.
4. **Remove the boot jumper** (return it to the normal boot position so the CM5 boots from eMMC next time).
5. Remove the CM5 from the IO board.

---

## Step 7 -- Repeat for all 4 modules

Repeat Steps 3 through 6 for each CM5 module, using a different hostname each time:

| Module | Hostname |
|--------|----------|
| 1 | `rpi-k3s-1` |
| 2 | `rpi-k3s-2` |
| 3 | `rpi-k3s-3` |
| 4 | `rpi-k3s-4` |

---

## Step 8 -- First boot

1. Seat each CM5 module into its final carrier board or cluster enclosure.
2. Connect Ethernet cables.
3. Power on all 4 modules.
4. Wait about 60-90 seconds for first boot to complete.

### Find your Pis on the network

If you set hostnames in the Imager settings, you may be able to reach them by
name right away (depending on your network):

```bash
ping rpi-k3s-1.local
```

If that does not work, check your UniFi dashboard (or your router's admin page)
for new DHCP leases to find the IPs. You will set static IPs in the next guide.

### First SSH connection

```bash
ssh myuser@<ip-address>
```

If you did **not** configure the password in Imager, the default is the one you set during flash and
you will be forced to change it immediately.

Verify you are on the right node:

```bash
hostname
cat /etc/os-release | head -3
```

You should see `rpi-k3s-1` (or whichever node) and `Ubuntu 24.04`.

---

## Step 9 -- Set hostname (if not done in Imager)

If you did not set the hostname during flashing, set it now on each Pi:

```bash
sudo hostnamectl set-hostname rpi-k3s-1
```

Then edit `/etc/hosts` to match:

```bash
sudo sed -i 's/127.0.1.1.*/127.0.1.1\trpi-k3s-1/' /etc/hosts
```

Repeat with the correct hostname for each node.

---

## Step 10 -- Verify SSH is enabled

SSH should be enabled by default on Ubuntu Server 24.04, but verify:

```bash
sudo systemctl status ssh
```

You should see `active (running)`. If not:

```bash
sudo systemctl enable --now ssh
```

---

## Checklist

Before moving on, confirm:

- [ ] All 4 CM5 modules are flashed with Ubuntu Server 24.04 LTS (64-bit ARM)
- [ ] All 4 are powered on, connected to Ethernet, and booted
- [ ] You can SSH into each one from your Mac
- [ ] Each has a unique hostname (`rpi-k3s-1` through `rpi-k3s-4`)
- [ ] SSH is running on all nodes

---

## Next step

[02 - Network Setup (Static IPs)](02-network-setup.md)
