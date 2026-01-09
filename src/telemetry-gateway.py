#!/usr/bin/env python3
import os
import socket
import struct
import time
from datetime import datetime, timezone

try:
    import psycopg2
except Exception:
    psycopg2 = None

UDP_HOST = os.getenv("UDP_HOST", "0.0.0.0")
UDP_PORT = int(os.getenv("UDP_PORT", "20777"))

DB_HOST = os.getenv("DB_HOST", "")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "f1")
DB_USER = os.getenv("DB_USER", "f1")
DB_PASS = os.getenv("DB_PASS") or os.getenv("DB_PASSWORD") or "f1pass"
DB_TABLE = os.getenv("DB_TABLE", "telemetry_stream")

SAMPLE_EVERY_N_FRAMES = int(os.getenv("SAMPLE_EVERY_N_FRAMES", "6"))

# PacketHeader (Codemasters/F1) - matches what we've been using
HDR_FMT = "<HBBBBBQfIIBb"
HDR_SIZE = struct.calcsize(HDR_FMT)

PID_CAR_TELEMETRY = 6

# CarTelemetryData (player car only)
TEL_FMT = "<HfffBbHBBH4H4B4BH4f4B"
TEL_SIZE = struct.calcsize(TEL_FMT)

def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()

def u64_to_i64(u: int) -> int:
    # Fit uint64 sessionUID into Postgres BIGINT safely
    return u - (1 << 64) if u >= (1 << 63) else u

def parse_header(data: bytes):
    if len(data) < HDR_SIZE:
        return None
    return struct.unpack_from(HDR_FMT, data, 0)

def parse_player_car_telemetry(data: bytes, player_idx: int):
    base = HDR_SIZE + (player_idx * TEL_SIZE)
    if len(data) < base + TEL_SIZE:
        return None
    return struct.unpack_from(TEL_FMT, data, base)

class DBWriter:
    def __init__(self):
        self.conn = None
        self.cur = None
        self.enabled = bool(DB_HOST) and (psycopg2 is not None)

    def connect(self):
        if not self.enabled:
            return False
        if self.conn is not None:
            return True

        for _ in range(30):
            try:
                self.conn = psycopg2.connect(
                    host=DB_HOST,
                    port=DB_PORT,
                    dbname=DB_NAME,
                    user=DB_USER,
                    password=DB_PASS,
                    connect_timeout=3,
                )
                self.conn.autocommit = True
                self.cur = self.conn.cursor()
                print(f"[DB] Connected to {DB_HOST}:{DB_PORT}/{DB_NAME} as {DB_USER}")
                return True
            except Exception as e:
                print(f"[DB] connect failed: {e} (retrying...)")
                time.sleep(1)

        print("[DB] Giving up (DB not reachable). Continuing log-only.")
        self.enabled = False
        return False

    def insert_row(self, row: dict):
        if not self.enabled:
            return
        if self.conn is None and not self.connect():
            return

        sql = f"""
        INSERT INTO {DB_TABLE} (
          ts, frame, session_uid,
          speed_kph, rpm, gear, throttle, brake, drs,
          tyre_temp_surface_rl, tyre_temp_surface_rr, tyre_temp_surface_fl, tyre_temp_surface_fr,
          tyre_temp_inner_rl, tyre_temp_inner_rr, tyre_temp_inner_fl, tyre_temp_inner_fr,
          brake_temp_rl, brake_temp_rr, brake_temp_fl, brake_temp_fr,
          engine_temp
        ) VALUES (
          %(ts)s, %(frame)s, %(session_uid)s,
          %(speed_kph)s, %(rpm)s, %(gear)s, %(throttle)s, %(brake)s, %(drs)s,
          %(tyre_temp_surface_rl)s, %(tyre_temp_surface_rr)s, %(tyre_temp_surface_fl)s, %(tyre_temp_surface_fr)s,
          %(tyre_temp_inner_rl)s, %(tyre_temp_inner_rr)s, %(tyre_temp_inner_fl)s, %(tyre_temp_inner_fr)s,
          %(brake_temp_rl)s, %(brake_temp_rr)s, %(brake_temp_fl)s, %(brake_temp_fr)s,
          %(engine_temp)s
        )
        """
        try:
            self.cur.execute(sql, row)
        except Exception as e:
            print(f"[DB] insert failed: {e}")

def main():
    if DB_HOST and psycopg2 is None:
        print("[WARN] DB_HOST set but psycopg2 is missing. Install psycopg2-binary or remove DB_HOST to run log-only.")

    db = DBWriter()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((UDP_HOST, UDP_PORT))
    print(f"[GW] Listening on {UDP_HOST}:{UDP_PORT}/udp")

    last_written_overall_frame = -1

    while True:
        data, addr = sock.recvfrom(4096)

        hdr = parse_header(data)
        if not hdr:
            continue

        (
            packet_format,
            game_year,
            game_major,
            game_minor,
            packet_version,
            packet_id,
            session_uid_u64,
            session_time,
            frame_id,
            overall_frame_id,
            player_car_index,
            secondary_player_index,
        ) = hdr

        if packet_id != PID_CAR_TELEMETRY:
            continue

        tel = parse_player_car_telemetry(data, int(player_car_index))
        if not tel:
            continue

        ofi = int(overall_frame_id)

        if SAMPLE_EVERY_N_FRAMES > 1:
            if ofi == last_written_overall_frame:
                continue
            if (ofi % SAMPLE_EVERY_N_FRAMES) != 0:
                continue
        last_written_overall_frame = ofi

        session_uid_db = u64_to_i64(int(session_uid_u64))

        (
            speed,
            throttle,
            steer,
            brake,
            clutch,
            gear,
            engine_rpm,
            drs,
            rev_lights_percent,
            rev_lights_bit_value,
            bt0, bt1, bt2, bt3,      # brakesTemp[4]   order: RL, RR, FL, FR
            st0, st1, st2, st3,      # tyresSurfaceTemp[4] order: RL, RR, FL, FR
            it0, it1, it2, it3,      # tyresInnerTemp[4]   order: RL, RR, FL, FR
            engine_temp,
            p0, p1, p2, p3,
            surf0, surf1, surf2, surf3,
        ) = tel

        row = {
            "ts": utc_now_iso(),
            "frame": ofi,
            "session_uid": session_uid_db,

            "speed_kph": int(speed),
            "rpm": int(engine_rpm),
            "gear": int(gear),
            "throttle": float(throttle),
            "brake": float(brake),
            "drs": int(drs),

            "tyre_temp_surface_rl": int(st0),
            "tyre_temp_surface_rr": int(st1),
            "tyre_temp_surface_fl": int(st2),
            "tyre_temp_surface_fr": int(st3),

            "tyre_temp_inner_rl": int(it0),
            "tyre_temp_inner_rr": int(it1),
            "tyre_temp_inner_fl": int(it2),
            "tyre_temp_inner_fr": int(it3),

            "brake_temp_rl": int(bt0),
            "brake_temp_rr": int(bt1),
            "brake_temp_fl": int(bt2),
            "brake_temp_fr": int(bt3),

            "engine_temp": int(engine_temp),
        }

        db.insert_row(row)

if __name__ == "__main__":
    main()