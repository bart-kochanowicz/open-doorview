# Turns OpenIPC's /etc/sensors/iq/imx307.ini into a GC2053 profile by replacing the noise-reduction arrays with the
# factory firmware's (Day_level0.xml, page NR: Auto.FineStr, Auto.CoringWeight, Auto.CoarseStr; the four CoarseStr
# groups are identical). Majestic uses the profile named after the sensor, so the result is installed as
# /etc/sensors/iq/gc2053.ini (see docs/night-vision.md).
#
# The line numbers are those of the imx307.ini with SHA-256
# f1948a713c0719e663c3ada6a27816a9751cbe12bc17b2ae5bf9c5e661e403e2 (the OpenIPC image on the unit). Check the hash
# first; for another file find the lines with: grep -n -E '^(FineStr|CoringWgt|CoarseStr_[0-3]) ' imx307.ini
# The two blocks are [static_nr] (by day) and [ir_static_nr] (used at night). Usage:
#   sed -f tools/gc2053-iq.sed imx307.ini > gc2053.ini
# The result has exactly 12 lines different (SHA-256 b8156eb44b040defba65e66a0f17f6c1c729d893b44566e5b9c08eeb848b67e6).
198s/^FineStr .*/FineStr = "108, 118, 128, 128, 128, 75, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80"/
1565s/^FineStr .*/FineStr = "108, 118, 128, 128, 128, 75, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80"/
199s/^CoringWgt .*/CoringWgt = "5, 5, 16, 20, 20, 20, 20, 20, 60, 60, 60, 60, 60, 60, 60, 60"/
1566s/^CoringWgt .*/CoringWgt = "5, 5, 16, 20, 20, 20, 20, 20, 60, 60, 60, 60, 60, 60, 60, 60"/
213,216s/^\(CoarseStr_[0-3]\) .*/\1 = "70, 90, 150, 150, 110, 120, 130, 150, 160, 170, 170, 170, 170, 170, 170, 170"/
1580,1583s/^\(CoarseStr_[0-3]\) .*/\1 = "70, 90, 150, 150, 110, 120, 130, 150, 160, 170, 170, 170, 170, 170, 170, 170"/
