# Raspberry Pi chess

Copy **this whole folder** to the Pi, open a terminal in it, and run:

```bash
python3 start.py
```

That is the same command on the first run and every later run. On Raspberry
Pi OS, the first run installs the native SPI package and enables SPI if needed.
It may ask for your sudo password. If enabling SPI requires a reboot, it says so.
The program prints the browser address when it starts. Ctrl+C stops it.

Everything the app reads is beside `start.py`. You can rename or move the
folder and run it again. No virtual environment, pip install, activation,
requirements path, web framework or service installation is needed. It keeps
your existing network. The old `setup.sh` and `run.sh` names simply start this
same program.

The app stops an older `de0cv-chess` service before starting on the Pi, so it
does not compete with that background copy. Stop any other manually started
SPI program before launching this one.

For a different HTTP port: `python3 start.py --port 8081`.
To check the copied files: `python3 start.py --check`.
To read the FPGA status: `python3 start.py --diagnose info`.

Use the matching advanced **DE0-CV** FPGA image. The SPI connection is mode 0,
1 MHz: Pi physical pins 23/19/21/24 connect to JP1 pins 1/2/3/4 respectively;
Pi ground connects to JP1 ground (pin 12 or 30). Use 3.3 V signals.
