"""game/state.py — Single source of truth for the current OpenTTD game state.

GameState is assembled incrementally from export packets sent by the GameScript.
``is_complete`` becomes True once all 6 EXPORT_END markers have been received.
"""

from __future__ import annotations
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Data model classes (one per export packet type)
# ---------------------------------------------------------------------------

@dataclass
class Industry:
    id:     int
    x:      int
    y:      int
    type:   str
    cargo:  str
    prod:   int
    served: bool
    trans_lm: int = 0
    served_lm: bool = False
    near_station: bool = False
    role:   str = "produces"
    coastal: bool = False


@dataclass
class Town:
    id:   int
    x:    int
    y:    int
    name: str
    pop:  int
    coastal: bool = False


@dataclass
class Company:
    id:   int
    name: str
    money: int
    loan:  int
    vehs:  int


@dataclass
class Engine:
    id:          int
    name:        str
    vtype:       str
    power:       int
    speed:       int
    cargo:       str
    cap:         int
    is_wagon:    bool  = False   # only present for TRAIN engines
    reliability: int   = 100    # current reliability percentage (0-100)
    refit:       str   = ""     # comma-separated cargo labels engine can refit to
    price:       int   = 0      # purchase cost at current game settings
    running_cost: int  = 0      # running cost per economy year


@dataclass
class Vehicle:
    id:           int
    company:      int
    type:         str
    name:         str
    profit_ly:    int
    profit_ty:    int
    age:          int
    running_cost: int
    status:       str
    cap:          int = 0
    cap_main:     int = 0
    cargo:        str = ""
    cap_by_cargo: dict[str, int] = field(default_factory=dict)


@dataclass
class Station:
    id:      int
    name:    str
    company: int
    x:       int
    y:       int
    train:   bool
    bus:     bool
    truck:   bool
    airport: bool
    dock:    bool
    town:    int   # nearest town id


# ---------------------------------------------------------------------------
# GameState — assembled from chunks, fires when complete
# ---------------------------------------------------------------------------

class GameState:
    """Accumulates all export chunks; ``is_complete`` signals a full snapshot."""

    _EXPECTED_CHUNKS = frozenset({"industries", "towns", "companies", "engines", "vehicles", "stations"})

    def __init__(self) -> None:
        # Industries are keyed by id; each id may have multiple cargo entries.
        self.industries: dict[int, list[Industry]] = {}
        self.towns:      dict[int, Town]           = {}
        self.companies:  dict[int, Company]        = {}
        self.engines:    dict[int, Engine]         = {}
        self.vehicles:   dict[int, Vehicle]        = {}
        self.stations:   dict[int, Station]        = {}
        self._received_ends: set[str]              = set()
        self.year:       int                       = 0
        self.month:      int                       = 0
        self.build_costs:    dict[str, int]        = {}


    @property
    def is_complete(self) -> bool:
        return self._received_ends >= self._EXPECTED_CHUNKS

    def reset(self) -> None:
        """Clear all accumulated state before starting a new export cycle."""
        self.industries.clear()
        self.towns.clear()
        self.companies.clear()
        self.engines.clear()
        self.vehicles.clear()
        self.stations.clear()
        self._received_ends.clear()
        self.year = 0
        self.month = 0
        self.build_costs = {}

    # ------------------------------------------------------------------
    # Packet ingestion
    # ------------------------------------------------------------------

    def ingest(self, data: dict) -> None:
        """Feed a single decoded packet dict into the appropriate collection."""
        t = data.get("t")
        if t == "INFO":
            raw_year = int(data.get("year", 0) or 0)
            # Some GameScript environments report year as an offset from 1949
            # (1 => 1950). Keep absolute years untouched.
            self.year = raw_year + 1949 if 0 < raw_year < 170 else raw_year
            self.month = data.get("month", 0)
            self.build_costs = {}
        elif t == "IND":
            self._ingest_industry(data)
        elif t == "TOWN":
            self._ingest_town(data)
        elif t == "CO":
            self._ingest_company(data)
        elif t == "ENG":
            self._ingest_engine(data)
        elif t == "VEH":
            self._ingest_vehicle(data)
        elif t == "STAT":
            self._ingest_station(data)
        elif t == "EXPORT_END":
            self._received_ends.add(data.get("chunk", ""))

    def _ingest_industry(self, d: dict) -> None:
        ind = Industry(
            id=d["id"], x=d["x"], y=d["y"],
            type=d["type"], cargo=d["cargo"],
            prod=d["prod"], served=d["served"],
            trans_lm=d.get("trans_lm", 0),
            served_lm=d.get("served_lm", d.get("served", False)),
            near_station=d.get("near_station", False),
            role=d.get("role", "produces"),
            coastal=d.get("coastal", False),
        )
        self.industries.setdefault(d["id"], []).append(ind)

    def _ingest_town(self, d: dict) -> None:
        self.towns[d["id"]] = Town(
            id=d["id"], x=d["x"], y=d["y"],
            name=d["name"], pop=d["pop"],
            coastal=d.get("coastal", False),
        )

    def _ingest_company(self, d: dict) -> None:
        self.companies[d["id"]] = Company(
            id=d["id"], name=d["name"],
            money=d["money"], loan=d["loan"], vehs=d["vehs"],
        )

    def _ingest_engine(self, d: dict) -> None:
        self.engines[d["id"]] = Engine(
            id=d["id"], name=d["name"],
            vtype=d.get("vtype", "UNKNOWN"),
            power=d["power"], speed=d["speed"],
            cargo=d["cargo"], cap=d["cap"],
            is_wagon=d.get("is_wagon", False),
            reliability=d.get("reliability", 100),
            refit=d.get("refit", ""),
            price=d.get("price", 0),
            running_cost=d.get("running_cost", 0),
        )

    def _ingest_vehicle(self, d: dict) -> None:
        cap_map = d.get("cap_by_cargo", {})
        if not isinstance(cap_map, dict):
            cap_map = {}

        self.vehicles[d["id"]] = Vehicle(
            id=d["id"], company=d["company"],
            type=d["type"], name=d["name"],
            profit_ly=d["profit_ly"], profit_ty=d["profit_ty"],
            age=d["age"], running_cost=d["running_cost"],
            status=d["status"],
            cap=d.get("cap", 0),
            cap_main=d.get("cap_main", d.get("cap", 0)),
            cargo=d.get("cargo", ""),
            cap_by_cargo=cap_map,
        )

    def _ingest_station(self, d: dict) -> None:
        self.stations[d["id"]] = Station(
            id=d["id"], name=d["name"],
            company=d["company"],
            x=d["x"], y=d["y"],
            train=bool(d.get("train", False)),
            bus=bool(d.get("bus", False)),
            truck=bool(d.get("truck", False)),
            airport=bool(d.get("airport", False)),
            dock=bool(d.get("dock", False)),
            town=d.get("town", 0),
        )
