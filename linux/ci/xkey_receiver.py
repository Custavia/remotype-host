#!/usr/bin/env python3
"""A window that writes down every key it receives — the last inch of the
typing path, after the X server and its layout have had their say.

Run under a display with the layout under test, then point the host at that
display and type through it. Each key press appends one line to the log:
    <keysym>\t<composed character or empty>
Dead keys show up as their keysym first, then the composed letter arrives on
the following key, which is exactly what a real desktop text field sees.

    Xvfb :99 -screen 0 800x600x24 &
    setxkbmap -display :99 es
    DISPLAY=:99 python3 ci/xkey_receiver.py /tmp/keys.log &
"""
import sys
import tkinter as tk

log_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/keys.log"
log = open(log_path, "a", buffering=1)

root = tk.Tk()
root.title("Remotype key receiver")
entry = tk.Entry(root, width=60, font=("Monospace", 16))
entry.pack(padx=20, pady=20)


def on_key(event):
    log.write(f"{event.keysym}\t{event.char}\n")


entry.bind("<KeyPress>", on_key)
root.after(200, lambda: (root.focus_force(), entry.focus_set()))
root.mainloop()
