#!/usr/bin/env python3
"""
ESP32 Serial Connection Diagnostic Tool
Tests serial connection and displays raw output from ESP32
"""

import serial
import serial.tools.list_ports
import time

def list_all_ports():
    """List all available COM ports"""
    print("\n" + "="*60)
    print("AVAILABLE COM PORTS:")
    print("="*60)
    ports = serial.tools.list_ports.comports()
    if not ports:
        print("No COM ports found!")
        return []

    for i, port in enumerate(ports, 1):
        print(f"{i}. {port.device}")
        print(f"   Description: {port.description}")
        print(f"   Hardware ID: {port.hwid}")
        print()
    return [port.device for port in ports]

def test_port(port_name, baud_rate=921600):
    """Test connection to a specific port"""
    print(f"\n{'='*60}")
    print(f"TESTING: {port_name} @ {baud_rate} baud")
    print(f"{'='*60}")

    try:
        ser = serial.Serial(port_name, baud_rate, timeout=2)
        print(f"[OK] Port opened successfully")
        print(f"Listening for data (10 seconds)...\n")

        start_time = time.time()
        data_received = False

        while time.time() - start_time < 10:
            if ser.in_waiting > 0:
                data = ser.readline()
                try:
                    decoded = data.decode('utf-8', errors='ignore').strip()
                    if decoded:
                        print(f"[{time.time() - start_time:.1f}s] {decoded}")
                        data_received = True
                except:
                    print(f"[{time.time() - start_time:.1f}s] RAW: {data}")
                    data_received = True
            time.sleep(0.1)

        if not data_received:
            print("[FAIL] No data received from ESP32")
            print("\nPossible issues:")
            print("  1. ESP32 code not uploaded")
            print("  2. ESP32 in boot loop or crashed")
            print("  3. Wrong baud rate")
            print("  4. USB cable is charge-only (no data)")
        else:
            print(f"\n[OK] Data received successfully!")

        ser.close()
        return data_received

    except serial.SerialException as e:
        print(f"[FAIL] Failed to open port: {e}")
        return False
    except Exception as e:
        print(f"[ERROR] Error: {e}")
        return False

def main():
    print("ESP32 SERIAL CONNECTION DIAGNOSTIC")
    print("="*60)

    # List all ports
    ports = list_all_ports()

    if not ports:
        print("\n[FAIL] No COM ports detected!")
        print("\nTroubleshooting steps:")
        print("1. Check USB cable is connected")
        print("2. Check ESP32 board has power (LED on?)")
        print("3. Install CH340/CP210x USB drivers if needed")
        print("4. Try a different USB port")
        print("5. Try a different USB cable (data capable)")
        return

    # Test COM3 first (your configured port)
    print("\nTesting COM3 (configured port) first...")
    if "COM3" in ports:
        success = test_port("COM3", 921600)
        if success:
            print("\n[OK] COM3 is working! Your ESP32 is ready.")
            return
    else:
        print("[FAIL] COM3 not found in available ports")

    # Ask user to test other ports
    print(f"\n{'='*60}")
    print("Would you like to test all other ports? (y/n): ", end='')
    response = input().strip().lower()

    if response == 'y':
        for port in ports:
            if port != "COM3":
                test_port(port, 921600)
                print()

    print("\n" + "="*60)
    print("DIAGNOSTIC COMPLETE")
    print("="*60)
    print("\nNext steps:")
    print("1. If no data received: Upload the ESP32 code using PlatformIO")
    print("2. If garbled data: Check baud rate (should be 921600)")
    print("3. If wrong port: Update platformio.ini upload_port setting")
    print("4. If 'Port busy': Close Arduino IDE, serial monitor, or other programs using the port")

if __name__ == "__main__":
    main()
