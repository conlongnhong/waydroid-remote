"""Bonjour / mDNS service announcement for automatic iOS discovery."""

from __future__ import annotations

import logging
import os
import shutil
import socket
import subprocess
import threading
from typing import Any, Dict, Optional

logger = logging.getLogger("discovery")


def get_lan_ip() -> str:
    """Detects the primary LAN IPv4 address reachable by other devices."""
    # Method 1: Connect UDP socket towards common LAN gateway to see routing decision
    for target in ("1.1.1.1", "8.8.8.8", "192.168.1.1"):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect((target, 80))
            ip = s.getsockname()[0]
            s.close()
            # Ensure it's not a waydroid container subnet or loopback
            if not ip.startswith("127.") and not ip.startswith("192.168.240."):
                return ip
        except Exception:
            continue

    # Method 2: Inspect network interfaces via hostname
    try:
        hostname = socket.gethostname()
        for ip in socket.gethostbyname_ex(hostname)[2]:
            if not ip.startswith("127.") and not ip.startswith("192.168.240."):
                return ip
    except Exception:
        pass

    return "127.0.0.1"


class BonjourPublisher:
    """Publishes _waydroid-remote._tcp service using python-zeroconf or avahi-publish."""

    def __init__(
        self,
        service_name: str = "Waydroid Remote",
        port: int = 8000,
        video_port: int = 8001,
        properties: Optional[Dict[str, str]] = None,
    ) -> None:
        self.service_name = service_name
        self.port = port
        self.video_port = video_port
        self.properties = properties or {}
        self.lan_ip = get_lan_ip()
        self._zeroconf = None
        self._service_info = None
        self._avahi_proc: Optional[subprocess.Popen] = None
        self._stop_event = threading.Event()

    def start(self) -> bool:
        """Starts advertising the service."""
        # Try python-zeroconf first if available
        try:
            from zeroconf import IPVersion, ServiceInfo, Zeroconf

            desc = {
                "name": self.service_name,
                "video_port": str(self.video_port),
                "control_port": str(self.port),
                "version": "2.0.0",
                **self.properties,
            }

            self._zeroconf = Zeroconf(ip_version=IPVersion.V4Only)
            self._service_info = ServiceInfo(
                type_="_waydroid-remote._tcp.local.",
                name=f"{self.service_name}._waydroid-remote._tcp.local.",
                addresses=[socket.inet_aton(self.lan_ip)],
                port=self.port,
                properties=desc,
                server=f"{socket.gethostname().split('.')[0]}.local.",
            )
            self._zeroconf.register_service(self._service_info)
            logger.info("Bonjour service registered via zeroconf: %s on %s:%d", self.service_name, self.lan_ip, self.port)
            return True
        except ImportError:
            logger.info("python-zeroconf not installed, falling back to avahi-publish...")
        except Exception as e:
            logger.warning("Failed to start zeroconf: %s. Trying avahi-publish...", e)

        # Fallback to avahi-publish CLI
        avahi_bin = shutil.which("avahi-publish") or shutil.which("avahi-publish-service")
        if avahi_bin:
            try:
                cmd = [
                    avahi_bin,
                    "-s",
                    self.service_name,
                    "_waydroid-remote._tcp",
                    str(self.port),
                    f"video_port={self.video_port}",
                    f"control_port={self.port}",
                    "version=2.0.0",
                ]
                for k, v in self.properties.items():
                    cmd.append(f"{k}={v}")

                self._avahi_proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                logger.info("Bonjour service registered via avahi-publish: %s on port %d", self.service_name, self.port)
                return True
            except Exception as e:
                logger.warning("Failed to run avahi-publish: %s", e)

        logger.warning(
            "Neither zeroconf nor avahi-publish available. Service discovery will rely on direct IP: %s",
            self.lan_ip,
        )
        return False

    def update_properties(self, properties: Dict[str, str]) -> None:
        self.properties.update(properties)
        if self._zeroconf and self._service_info:
            try:
                self._service_info.properties.update({k.encode(): v.encode() for k, v in properties.items()})
                self._zeroconf.update_service(self._service_info)
            except Exception as e:
                logger.debug("Error updating zeroconf properties: %s", e)

    def stop(self) -> None:
        """Stops advertising the service."""
        self._stop_event.set()
        if self._zeroconf and self._service_info:
            try:
                self._zeroconf.unregister_service(self._service_info)
                self._zeroconf.close()
                logger.info("Unregistered zeroconf service.")
            except Exception as e:
                logger.debug("Error stopping zeroconf: %s", e)
            self._zeroconf = None
            self._service_info = None

        if self._avahi_proc:
            try:
                self._avahi_proc.terminate()
                self._avahi_proc.wait(timeout=1.0)
            except Exception:
                try:
                    self._avahi_proc.kill()
                except Exception:
                    pass
            self._avahi_proc = None
            logger.info("Terminated avahi-publish process.")
