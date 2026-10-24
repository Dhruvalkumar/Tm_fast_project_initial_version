from pymodbus.client import ModbusSerialClient
from collections import deque
import statistics
import time

# --- Configuration ---
PORT = 'COM5'
SLAVE_ID = 12
BAUDRATE = 19200
MIN_MM = 100
MAX_MM = 1500
ROLLING_WINDOW_SIZE = 5
DELTA_REJECT_THRESHOLD = 300
SAMPLE_COUNT = 3
TRIGGER_DELAY = 0.1
SPIKE_RECOVERY_COUNT = 4

# --- Modbus Client Setup ---
client = ModbusSerialClient(
    port=PORT,
    baudrate=BAUDRATE,
    parity='N',
    stopbits=1,
    bytesize=8,
    timeout=1
)

# --- State ---
distance_window = deque(maxlen=ROLLING_WINDOW_SIZE)
last_valid_distance = None
spike_counter = 0

# --- Functions ---
def read_register(address):
    res = client.read_holding_registers(address=address, count=1, slave=SLAVE_ID)
    if not res.isError():
        return res.registers[0]
    return None

def trigger_measurement():
    client.write_register(address=0x08, value=0x000C, slave=SLAVE_ID)

def get_raw_distance():
    trigger_measurement()
    time.sleep(TRIGGER_DELAY)
    raw = read_register(0x05)
    if raw and raw != 0xFFFF:
        return raw / 10.0
    time.sleep(0.1)
    raw_retry = read_register(0x05)
    return raw_retry / 10.0 if raw_retry and raw_retry != 0xFFFF else None

def get_temperature():
    raw = read_register(0x06)
    return raw / 10.0 if raw and raw != 0xFFFF else 25.0

def get_average_sample():
    readings = []
    for _ in range(SAMPLE_COUNT):
        d = get_raw_distance()
        if d:
            readings.append(d)
        time.sleep(0.05)
    return sum(readings) / len(readings) if readings else None

def temperature_compensated(dist, temp_c):
    speed = 331.0 + 0.6 * temp_c
    return dist * (speed / 343.0)

def apply_filters(corrected):
    global last_valid_distance, spike_counter

    if last_valid_distance is not None:
        delta = abs(corrected - last_valid_distance)
        if delta > DELTA_REJECT_THRESHOLD:
            spike_counter += 1
            print(f"⚠️ Spike rejected ({delta:.1f} mm diff): {corrected:.1f} [{spike_counter}/{SPIKE_RECOVERY_COUNT}]")
            if spike_counter >= SPIKE_RECOVERY_COUNT:
                print("✅ Adopting new value after repeated changes.")
                last_valid_distance = corrected
                spike_counter = 0
                return corrected
            return None
        else:
            spike_counter = 0

    distance_window.append(corrected)
    filtered = statistics.median(distance_window)
    last_valid_distance = filtered
    return filtered

# --- Main Loop ---
if client.connect():
    print("✅ Connected to URM14 Sensor")
    try:
        while True:
            avg_distance = get_average_sample()
            temp_c = get_temperature()

            if avg_distance is None or not (MIN_MM <= avg_distance <= MAX_MM):
                print("⚠️ Out-of-range or invalid reading")
                continue

            corrected = temperature_compensated(avg_distance, temp_c)
            filtered = apply_filters(corrected)

            if filtered:
                print(f"📏 Distance: {filtered:.1f} mm | 🌡 Temp: {temp_c:.1f} °C")
            else:
                print("⚠️ Value filtered out (not stable enough)")

            time.sleep(0.5)

    finally:
        client.close()
        print("🔌 Disconnected from sensor.")
else:
    print("❌ Could not connect to sensor. Check COM port.")
