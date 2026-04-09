#!/usr/bin/env python3
"""Quick script to list available COM ports"""
import serial.tools.list_ports

print("\nAvailable COM Ports:")
print("=" * 60)
ports = serial.tools.list_ports.comports()
if not ports:
    print("No COM ports found!")
else:
    for port in ports:
        print(f"\nPort: {port.device}")
        print(f"  Description: {port.description}")
        print(f"  Hardware ID: {port.hwid}")
print("=" * 60)
