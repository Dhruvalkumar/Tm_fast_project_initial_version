from pymodbus.client import ModbusSerialClient
from collections import deque
import tkinter as tk
from tkinter import ttk
import matplotlib.pyplot as plt
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
import csv
import time
import statistics

# --- Configuration ---
PORT = 'COM5'
SLAVE_ID = 12
BAUDRATE = 19200
MIN_MM = 100
MAX_MM = 1500
ROLLING_WINDOW_SIZE = 5
DELTA_REJECT_THRESHOLD = 300
SAMPLE_COUNT = 3
MAX_LOG_ROWS = 1000
CSV_FILE = 'sensor_data.csv'

# --- Modbus Client ---
client = ModbusSerialClient(
    port=PORT, baudrate=BAUDRATE, parity='N', stopbits=1,
    bytesize=8, timeout=1
)

# --- State ---
distance_window = deque(maxlen=ROLLING_WINDOW_SIZE)
last_valid_distance = None
log_counter = 0

# --- Functions ---
def read_register(address):
    response = client.read_holding_registers(address=address, count=1, slave=SLAVE_ID)
    if not response.isError():
        return response.registers[0]
    return None

def temperature_compensated(raw_distance, temp_c):
    speed = 331.0 + 0.6 * temp_c
    return raw_distance * (speed / 343.0)

def get_average_sample():
    readings = []
    for _ in range(SAMPLE_COUNT):
        client.write_register(address=0x08, value=0x000C, slave=SLAVE_ID)
        time.sleep(0.3)
        raw_distance = read_register(0x05)
        if raw_distance is not None and raw_distance != 0xFFFF:
            readings.append(raw_distance / 10.0)
        time.sleep(0.1)
    return sum(readings) / len(readings) if readings else None

def get_temperature():
    raw_temp = read_register(0x06)
    return raw_temp / 10.0 if raw_temp is not None and raw_temp != 0xFFFF else 25.0

def apply_filters(corrected_distance):
    global last_valid_distance
    if last_valid_distance is not None:
        if abs(corrected_distance - last_valid_distance) > DELTA_REJECT_THRESHOLD:
            return None
    distance_window.append(corrected_distance)
    filtered = statistics.median(distance_window)
    last_valid_distance = filtered
    return filtered

def determine_motor_state(distance):
    if distance < 400:
        return "REV"
    elif 400 <= distance <= 800:
        return "NEU"
    else:
        return "FWD"

def write_to_csv(dist, comp, filt, temp, state):
    global log_counter
    if log_counter >= MAX_LOG_ROWS:
        return
    with open(CSV_FILE, mode='a', newline='') as f:
        writer = csv.writer(f)
        writer.writerow([time.strftime('%H:%M:%S'), dist, comp, filt, temp, state])
        log_counter += 1

# --- GUI Setup ---
root = tk.Tk()
root.title("URM14 Live Dashboard")
fig, ax = plt.subplots()
canvas = FigureCanvasTkAgg(fig, master=root)
canvas.get_tk_widget().pack()

distance_data, temp_data, time_data = [], [], []

label_status = ttk.Label(root, text="Connecting...", font=("Arial", 12))
label_status.pack(pady=5)

motor_label = ttk.Label(root, text="", font=("Arial", 14, "bold"))
motor_label.pack()

def update_plot():
    ax.clear()
    ax.plot(time_data, distance_data, label="Distance (mm)")
    ax.plot(time_data, temp_data, label="Temperature (°C)", linestyle='--')
    ax.set_xlabel("Time")
    ax.set_ylabel("Value")
    ax.legend()
    ax.grid(True)
    fig.tight_layout()
    canvas.draw()

def update_sensor_data():
    if not client.connect():
        label_status.config(text="❌ Failed to connect")
        return

    try:
        distance_mm = get_average_sample()
        temp_c = get_temperature()

        if distance_mm is None or not (MIN_MM <= distance_mm <= MAX_MM):
            label_status.config(text="⚠️ Out-of-range reading")
        else:
            corrected = temperature_compensated(distance_mm, temp_c)
            filtered = apply_filters(corrected)

            if filtered:
                motor_state = determine_motor_state(filtered)
                current_time = time.strftime('%H:%M:%S')

                # Update data lists
                distance_data.append(filtered)
                temp_data.append(temp_c)
                time_data.append(current_time)

                # Limit displayed data points
                if len(time_data) > 50:
                    distance_data.pop(0)
                    temp_data.pop(0)
                    time_data.pop(0)

                # Update GUI
                motor_label.config(text=f"Motor State: {motor_state}")
                label_status.config(
                    text=f"Distance: {filtered:.1f} mm | Temp: {temp_c:.1f} °C")

                # Log data
                write_to_csv(distance_mm, corrected, filtered, temp_c, motor_state)

                update_plot()

    except Exception as e:
        label_status.config(text=f"Error: {e}")
    finally:
        root.after(1500, update_sensor_data)

# --- CSV Header ---
with open(CSV_FILE, mode='w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(["Timestamp", "RawDistance", "Compensated", "Filtered", "Temperature", "MotorState"])

# --- Start GUI Loop ---
root.after(1000, update_sensor_data)
root.mainloop()
client.close()
