# edge_roku
SmartThings Edge Driver for Roku devices

This driver is currently under development and test. Although the driver has full functionality, there are significant enough issues with the current Edge platform beta that prevent this driver from being ready for general use.  Awaiting next firmware release to see if some of these problems are cleared up.

## Currently known issues
```
- socket bugs:
    runtime error: [string "socket"]:205: received data on non-existent socket: tcp_send_ready
    runtime error: [string "cosock"]:296: cosock tried to call socket.select with no sockets and no timeout. this is a bug, please report it
- tV capability not displaying
- mediaPlayback Fast forward button not working
- Selection lists in random order
- info_changed lifecycle can be invoked multiple times with erroneous data from one preferenes Settings change
- Driver restart lifecycle handler not called; instead info_changed is called
```
