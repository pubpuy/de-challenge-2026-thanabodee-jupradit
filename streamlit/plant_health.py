# Plant Health at a Glance — Streamlit Dashboard for DE Challenge 2026
import os
import streamlit as st
import pandas as pd
import altair as alt

# ── Page config ─────────────────────────────────────────────────────────────
try:
    st.set_page_config(
        page_title="Plant Health at a Glance",
        page_icon="🏭",
        layout="wide",
    )
except Exception:
    pass

# ── Design tokens (single source of truth) ──────────────────────────────────
COLORS = {
    "good":    "#2d9e2d",
    "warn":    "#e6a817",
    "bad":     "#c0392b",
    "neutral": "#3498db",
    "muted":   "#95a5a6",
}

ICONS = {"good": "🟢", "warn": "🟡", "bad": "🔴"}

THRESHOLDS = {
    "uptime_good":      70.0,
    "uptime_warn":      50.0,
    "vib_zone_c":        4.5,
    "vib_zone_d":       11.2,
}

# Zone ISO class — A/B = good, C = warn, D = bad
ZONE_STATUS = {"A": "good", "B": "good", "C": "warn", "D": "bad"}


def get_status(value: float, good_thresh: float, warn_thresh: float,
               higher_is_better: bool = True) -> str:
    """Return 'good' | 'warn' | 'bad' for any metric."""
    if higher_is_better:
        if value >= good_thresh:
            return "good"
        if value >= warn_thresh:
            return "warn"
        return "bad"
    else:
        if value <= good_thresh:
            return "good"
        if value <= warn_thresh:
            return "warn"
        return "bad"


def status_icon(status: str) -> str:
    return ICONS.get(status, "⚪")


# ── Altair theme (registered once — all charts inherit) ────────────────────
def _dashboard_theme():
    return {
        "config": {
            "view":   {"continuousWidth": 400, "continuousHeight": 280},
            "axis":   {"labelFontSize": 11, "titleFontSize": 12,
                       "gridColor": "#eaeaea", "domainColor": "#cccccc"},
            "title":  {"fontSize": 13, "fontWeight": "bold", "anchor": "start",
                       "offset": 8},
            "legend": {"labelFontSize": 11, "titleFontSize": 11},
            "range":  {
                "category": [
                    COLORS["good"], COLORS["neutral"],
                    COLORS["warn"], COLORS["bad"], COLORS["muted"],
                ]
            },
        }
    }

alt.themes.register("dashboard", _dashboard_theme)
alt.themes.enable("dashboard")

# ── Minimal CSS (data-testid selectors — stable across Streamlit versions) ──
st.markdown("""
<style>
[data-testid="stMetricValue"] { font-size: 1.55rem; font-weight: 700; }
[data-testid="stMetricLabel"] { font-size: 0.82rem; font-weight: 600; opacity: 0.75; }
</style>
""", unsafe_allow_html=True)

# ── Connection ───────────────────────────────────────────────────────────────
conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))


# ── Data loaders ─────────────────────────────────────────────────────────────
@st.cache_data(ttl=900)
def load_production_summary():
    return conn.query("""
        SELECT
            MACHINE_GROUP,
            COUNT(DISTINCT ASSET)                AS machines,
            ROUND(AVG(UPTIME_PCT), 1)            AS avg_uptime_pct,
            SUM(PARTS_PRODUCED)                  AS total_parts,
            ROUND(AVG(PRODUCTIVE_READINGS * 100.0 / NULLIF(TOTAL_READINGS, 0)), 1) AS productive_pct,
            ROUND(AVG(PLANNED_STOP_READINGS * 100.0 / NULLIF(TOTAL_READINGS, 0)), 1) AS planned_stop_pct,
            ROUND(AVG(UNPLANNED_DT_READINGS * 100.0 / NULLIF(TOTAL_READINGS, 0)), 1) AS unplanned_dt_pct,
            ROUND(AVG(EXCLUDED_READINGS * 100.0 / NULLIF(TOTAL_READINGS, 0)), 1) AS excluded_pct
        FROM DE_CHALLENGE.GOLD.PRODUCTION_HOURLY
        GROUP BY MACHINE_GROUP
        ORDER BY avg_uptime_pct DESC
    """)


@st.cache_data(ttl=900)
def load_setup_top10():
    return conn.query("""
        SELECT
            ASSET,
            MACHINE_GROUP,
            ROUND(SUM(SETUP_MINUTES) / 60.0, 1)  AS total_setup_hrs,
            ROUND(SUM(SETUP_MINUTES) / NULLIF(SUM(TOTAL_READINGS), 0) * 100, 1) AS setup_pct
        FROM DE_CHALLENGE.GOLD.PRODUCTION_HOURLY
        GROUP BY ASSET, MACHINE_GROUP
        ORDER BY total_setup_hrs DESC
        LIMIT 10
    """)


@st.cache_data(ttl=900)
def load_vibration_summary():
    return conn.query("""
        SELECT
            ASSET,
            ROUND(AVG(AVG_RMS_VELOCITY), 2)       AS avg_rms,
            ROUND(MAX(MAX_RMS_VELOCITY), 2)        AS max_rms,
            ROUND(AVG(AVG_RPM), 0)                 AS avg_rpm,
            ROUND(AVG(AVG_TEMPERATURE_C), 1)       AS avg_temp_c,
            ROUND(AVG(AVG_CREST_FACTOR), 2)        AS avg_crest,
            SUM(READINGS_ZONE_A)                   AS zone_a,
            SUM(READINGS_ZONE_B)                   AS zone_b,
            SUM(READINGS_ZONE_C)                   AS zone_c,
            SUM(READINGS_ZONE_D)                   AS zone_d,
            CASE
                WHEN SUM(READINGS_ZONE_D) >= SUM(READINGS_ZONE_C)
                 AND SUM(READINGS_ZONE_D) >= SUM(READINGS_ZONE_B)
                 AND SUM(READINGS_ZONE_D) >= SUM(READINGS_ZONE_A) THEN 'D'
                WHEN SUM(READINGS_ZONE_C) >= SUM(READINGS_ZONE_B)
                 AND SUM(READINGS_ZONE_C) >= SUM(READINGS_ZONE_A) THEN 'C'
                WHEN SUM(READINGS_ZONE_B) >= SUM(READINGS_ZONE_A) THEN 'B'
                ELSE 'A'
            END                                    AS dominant_zone
        FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY
        GROUP BY ASSET
        ORDER BY ASSET
    """)


@st.cache_data(ttl=900)
def load_vibration_trend():
    return conn.query("""
        SELECT
            ASSET,
            DATE_TRUNC('DAY', HOUR_LOCAL)          AS day_local,
            ROUND(AVG(AVG_RMS_VELOCITY), 3)        AS daily_avg_rms,
            ROUND(AVG(ROLLING_7DAY_AVG_RMS), 3)    AS rolling_7d_rms,
            MAX(DOMINANT_ISO_ZONE)                 AS worst_zone
        FROM DE_CHALLENGE.GOLD.VIBRATION_HOURLY
        WHERE ASSET IN ('motor_02', 'motor_01')
        GROUP BY ASSET, day_local
        ORDER BY day_local
    """)


@st.cache_data(ttl=900)
def load_energy_by_floor():
    return conn.query("""
        SELECT
            ASSET,
            FLOOR_NUM,
            ROUND(SUM(TOTAL_KWH), 0)            AS total_kwh,
            ROUND(SUM(TOTAL_COST_BAHT), 0)      AS total_cost_baht,
            ROUND(SUM(PEAK_KWH), 0)             AS peak_kwh,
            ROUND(SUM(OFFPEAK_KWH), 0)          AS offpeak_kwh,
            ROUND(AVG(AVG_POWER_FACTOR), 3)     AS avg_pf,
            ROUND(MIN(MIN_POWER_FACTOR), 3)     AS min_pf,
            SUM(LOW_PF_HOURS)                   AS low_pf_hours
        FROM DE_CHALLENGE.GOLD.ENERGY_DAILY
        WHERE IS_ANOMALY = FALSE
          AND ASSET != 'MAIN-MDB'
        GROUP BY ASSET, FLOOR_NUM
        ORDER BY total_kwh DESC
    """)


@st.cache_data(ttl=900)
def load_energy_weekday_vs_weekend():
    return conn.query("""
        SELECT
            IS_WEEKEND,
            COUNT(DISTINCT DAY_LOCAL)           AS day_count,
            ROUND(AVG(TOTAL_KWH), 1)            AS avg_daily_kwh,
            ROUND(AVG(TOTAL_COST_BAHT), 0)      AS avg_daily_cost_baht,
            ROUND(SUM(TOTAL_KWH), 0)            AS total_kwh,
            ROUND(SUM(TOTAL_COST_BAHT), 0)      AS total_cost_baht
        FROM DE_CHALLENGE.GOLD.ENERGY_DAILY
        WHERE ASSET = 'MAIN-MDB'
        GROUP BY IS_WEEKEND
        ORDER BY IS_WEEKEND
    """)


@st.cache_data(ttl=900)
def load_energy_daily_trend():
    return conn.query("""
        SELECT
            DAY_LOCAL,
            IS_WEEKEND,
            ROUND(TOTAL_KWH, 0)                 AS total_kwh,
            ROUND(TOTAL_COST_BAHT, 0)           AS cost_baht
        FROM DE_CHALLENGE.GOLD.ENERGY_DAILY
        WHERE ASSET = 'MAIN-MDB'
        ORDER BY DAY_LOCAL
    """)


@st.cache_data(ttl=900)
def load_last_refresh():
    return conn.query("""
        SELECT MAX(LOADED_AT) AS last_refresh
        FROM DE_CHALLENGE.GOLD.PRODUCTION_HOURLY
    """)


# ── Load data ────────────────────────────────────────────────────────────────
df_prod      = load_production_summary()
df_setup     = load_setup_top10()
df_vib       = load_vibration_summary()
df_trend     = load_vibration_trend()
df_energy_floor   = load_energy_by_floor()
df_energy_wdwe    = load_energy_weekday_vs_weekend()
df_energy_trend   = load_energy_daily_trend()
df_refresh   = load_last_refresh()

last_refresh   = df_refresh["LAST_REFRESH"].iloc[0] if not df_refresh.empty else "Unknown"
avg_uptime_all = float(df_prod["AVG_UPTIME_PCT"].mean()) if not df_prod.empty else 0.0
motor02_zone   = df_vib.loc[df_vib["ASSET"] == "motor_02", "DOMINANT_ZONE"].values
motor02_zone   = motor02_zone[0] if len(motor02_zone) > 0 else "?"
zone_d_alert   = motor02_zone == "D"

prod_status  = get_status(avg_uptime_all,
                          THRESHOLDS["uptime_good"], THRESHOLDS["uptime_warn"])
vib_status   = ZONE_STATUS.get(motor02_zone, "bad")
plant_status = "bad" if (prod_status == "bad" or vib_status == "bad") else \
               "warn" if (prod_status == "warn" or vib_status == "warn") else "good"

PLANT_LABELS = {"good": "Healthy", "warn": "Monitor", "bad": "Action Required"}


# ════════════════════════════════════════════════════════════════════════════
# PAGE HEADER
# ════════════════════════════════════════════════════════════════════════════
st.title("🏭 Plant Health at a Glance")

with st.container():
    col_status, col_refresh, col_uptime, col_vib = st.columns(4)
    with col_status:
        st.metric(
            "Overall Status",
            f"{status_icon(plant_status)} {PLANT_LABELS[plant_status]}",
        )
    with col_refresh:
        st.metric("Data as of", str(last_refresh)[:16] if last_refresh != "Unknown" else "—")
    with col_uptime:
        st.metric(
            "Avg Production Uptime",
            f"{avg_uptime_all:.1f}%",
            delta=f"Target: {int(THRESHOLDS['uptime_good'])}%",
        )
    with col_vib:
        st.metric(
            "motor_02 ISO Zone",
            f"{status_icon(vib_status)} Zone {motor02_zone}",
            delta="CRITICAL — inspect now" if zone_d_alert else "Normal",
            delta_color="inverse" if zone_d_alert else "normal",
        )

if zone_d_alert:
    st.error(
        f"motor_02 is in ISO Zone D (RMS > {THRESHOLDS['vib_zone_d']} mm/s) — "
        "stop and inspect immediately."
    )
elif plant_status == "warn":
    st.warning("One or more metrics need attention. See tabs below.")


# ════════════════════════════════════════════════════════════════════════════
# TABS
# ════════════════════════════════════════════════════════════════════════════
tab_prod, tab_vib, tab_energy = st.tabs(["Production Health", "Vibration Health", "Energy"])


# ════════════════════════════════════════════════════════════════════════════
# TAB 1 — PRODUCTION HEALTH
# ════════════════════════════════════════════════════════════════════════════
with tab_prod:
    # ── Uptime metric cards ──────────────────────────────────────────────────
    st.subheader("Uptime by Machine Group")

    if not df_prod.empty:
        with st.container():
            cols = st.columns(len(df_prod))
            for i, row in df_prod.iterrows():
                s = get_status(float(row["AVG_UPTIME_PCT"]),
                               THRESHOLDS["uptime_good"], THRESHOLDS["uptime_warn"])
                with cols[i]:
                    st.metric(
                        label=f"{status_icon(s)} {row['MACHINE_GROUP']} ({int(row['MACHINES'])} machines)",
                        value=f"{row['AVG_UPTIME_PCT']}%",
                        delta=f"{int(row['TOTAL_PARTS']):,} parts",
                    )
    else:
        st.info("No production data available.")

    # ── 1b: Uptime bar chart ─────────────────────────────────────────────────
    if not df_prod.empty:
        chart_df = df_prod[["MACHINE_GROUP", "AVG_UPTIME_PCT"]].copy()
        chart_df.columns = ["Group", "Uptime %"]
        chart_df["Status"] = chart_df["Uptime %"].apply(
            lambda x: get_status(x, THRESHOLDS["uptime_good"], THRESHOLDS["uptime_warn"])
        )
        chart_df["Color"] = chart_df["Status"].map(COLORS)

        bar = (
            alt.Chart(chart_df)
            .mark_bar(cornerRadiusTopLeft=3, cornerRadiusTopRight=3)
            .encode(
                x=alt.X("Group:N", axis=alt.Axis(title="Machine Group", labelAngle=0)),
                y=alt.Y("Uptime %:Q",
                        scale=alt.Scale(domain=[0, 100]),
                        axis=alt.Axis(title="Avg Uptime %")),
                color=alt.Color(
                    "Color:N",
                    scale=alt.Scale(
                        domain=list(COLORS.values()),
                        range=list(COLORS.values()),
                    ),
                    legend=None,
                ),
                tooltip=[
                    alt.Tooltip("Group:N", title="Group"),
                    alt.Tooltip("Uptime %:Q", title="Avg Uptime %", format=".1f"),
                ],
            )
        )

        rules = pd.DataFrame([
            {"y": THRESHOLDS["uptime_good"], "label": f"Good ≥{int(THRESHOLDS['uptime_good'])}%",
             "color": COLORS["good"]},
            {"y": THRESHOLDS["uptime_warn"], "label": f"Warn ≥{int(THRESHOLDS['uptime_warn'])}%",
             "color": COLORS["warn"]},
        ])
        threshold_lines = (
            alt.Chart(rules)
            .mark_rule(strokeDash=[6, 3], strokeWidth=1.5)
            .encode(
                y=alt.Y("y:Q"),
                color=alt.Color("color:N",
                                scale=alt.Scale(domain=rules["color"].tolist(),
                                                range=rules["color"].tolist()),
                                legend=None),
            )
        )

        st.altair_chart(
            (bar + threshold_lines).properties(title="Average Uptime % by Group"),
            use_container_width=True,
        )
        st.caption(f"Target ≥{int(THRESHOLDS['uptime_good'])}% (green) · Alert <{int(THRESHOLDS['uptime_warn'])}% (yellow)")

    # ── Downtime stacked chart ───────────────────────────────────────────────
    if not df_prod.empty:
        st.subheader("Time Breakdown by Group")

        cat_colors = {
            "Productive":   COLORS["good"],
            "Planned Stop": COLORS["neutral"],
            "Unplanned DT": COLORS["bad"],
            "No Order":     COLORS["muted"],
        }

        stacked_data = []
        for _, row in df_prod.iterrows():
            g = row["MACHINE_GROUP"]
            stacked_data += [
                {"Group": g, "Category": "Productive",   "Pct": float(row["PRODUCTIVE_PCT"])},
                {"Group": g, "Category": "Planned Stop", "Pct": float(row["PLANNED_STOP_PCT"])},
                {"Group": g, "Category": "Unplanned DT", "Pct": float(row["UNPLANNED_DT_PCT"])},
                {"Group": g, "Category": "No Order",     "Pct": float(row["EXCLUDED_PCT"])},
            ]

        stacked_df = pd.DataFrame(stacked_data)
        stacked_chart = (
            alt.Chart(stacked_df)
            .mark_bar()
            .encode(
                x=alt.X("Group:N", axis=alt.Axis(title=None, labelAngle=0)),
                y=alt.Y("Pct:Q", stack="normalize",
                        axis=alt.Axis(format="%", title="Share of time")),
                color=alt.Color(
                    "Category:N",
                    scale=alt.Scale(
                        domain=list(cat_colors.keys()),
                        range=list(cat_colors.values()),
                    ),
                    legend=alt.Legend(title="Category", orient="right"),
                ),
                tooltip=[
                    alt.Tooltip("Group:N"),
                    alt.Tooltip("Category:N"),
                    alt.Tooltip("Pct:Q", format=".1f", title="Avg %"),
                ],
            )
            .properties(title="Downtime Category Breakdown (normalized)")
        )
        st.altair_chart(stacked_chart, use_container_width=True)

    # ── Setup time table ─────────────────────────────────────────────────────
    st.subheader("Setup & Changeover Time")

    if not df_setup.empty:
        df_s = df_setup.copy()
        df_s.columns = ["Machine", "Group", "Total Setup (hrs)", "Setup %"]
        st.dataframe(
            df_s,
            use_container_width=True,
            hide_index=True,
            column_config={
                "Setup %": st.column_config.ProgressColumn(
                    "Setup %",
                    format="%.1f%%",
                    min_value=0,
                    max_value=100,
                ),
                "Total Setup (hrs)": st.column_config.NumberColumn(format="%.1f"),
            },
        )
    else:
        st.info("No setup data available.")


# ════════════════════════════════════════════════════════════════════════════
# TAB 2 — VIBRATION HEALTH
# ════════════════════════════════════════════════════════════════════════════
with tab_vib:
    # ── Motor status cards ───────────────────────────────────────────────────
    st.subheader("ISO Zone per Motor")

    if not df_vib.empty:
        with st.container():
            motor_cols = st.columns(len(df_vib))
            for i, row in df_vib.iterrows():
                s = ZONE_STATUS.get(str(row["DOMINANT_ZONE"]), "bad")
                with motor_cols[i]:
                    st.metric(
                        label=f"{status_icon(s)} {row['ASSET']}",
                        value=f"Zone {row['DOMINANT_ZONE']}",
                        delta=f"Avg {float(row['AVG_RMS']):.2f} mm/s",
                        delta_color="inverse" if s in ("warn", "bad") else "normal",
                    )
                    st.caption(
                        f"Max: {float(row['MAX_RMS']):.2f} mm/s · "
                        f"{float(row['AVG_TEMP_C']):.1f}°C"
                    )
    else:
        st.info("No vibration data available.")

    # ── motor_02 zone distribution ───────────────────────────────────────────
    st.subheader("motor_02 — Zone Distribution")

    m02 = df_vib[df_vib["ASSET"] == "motor_02"]
    if not m02.empty:
        row  = m02.iloc[0]
        total = sum(int(row[z]) for z in ("ZONE_A", "ZONE_B", "ZONE_C", "ZONE_D"))

        if total > 0:
            zone_dist = pd.DataFrame({
                "Zone":     [
                    f"Zone A (<1.8 mm/s)",
                    f"Zone B (1.8–{THRESHOLDS['vib_zone_c']} mm/s)",
                    f"Zone C ({THRESHOLDS['vib_zone_c']}–{THRESHOLDS['vib_zone_d']} mm/s)",
                    f"Zone D (>{THRESHOLDS['vib_zone_d']} mm/s)",
                ],
                "Zone_label": ["A", "B", "C", "D"],
                "Readings": [int(row["ZONE_A"]), int(row["ZONE_B"]),
                             int(row["ZONE_C"]), int(row["ZONE_D"])],
                "Color":    [COLORS["good"], COLORS["neutral"],
                             COLORS["warn"], COLORS["bad"]],
            })
            zone_dist["Pct"] = (zone_dist["Readings"] / total * 100).round(1)

            col_pie, col_detail = st.columns([1, 1])
            with col_pie:
                pie = (
                    alt.Chart(zone_dist)
                    .mark_arc(innerRadius=60)
                    .encode(
                        theta=alt.Theta("Readings:Q"),
                        color=alt.Color(
                            "Zone_label:N",
                            scale=alt.Scale(
                                domain=zone_dist["Zone_label"].tolist(),
                                range=zone_dist["Color"].tolist(),
                            ),
                            legend=alt.Legend(title="ISO Zone"),
                        ),
                        tooltip=[
                            alt.Tooltip("Zone:N"),
                            alt.Tooltip("Readings:Q", format=","),
                            alt.Tooltip("Pct:Q", format=".1f", title="Pct %"),
                        ],
                    )
                    .properties(title="motor_02 Zone Distribution")
                )
                st.altair_chart(pie, use_container_width=True)

            with col_detail:
                st.dataframe(
                    zone_dist[["Zone", "Readings", "Pct"]].rename(columns={"Pct": "Pct %"}),
                    use_container_width=True,
                    hide_index=True,
                )
                st.metric(
                    "Avg RMS",
                    f"{float(row['AVG_RMS']):.2f} mm/s",
                    delta=f"Zone D threshold: {THRESHOLDS['vib_zone_d']} mm/s",
                    delta_color="inverse",
                )
    else:
        st.info("No motor_02 data available.")

    # ── RMS trend ────────────────────────────────────────────────────────────
    st.subheader("Vibration Trend")

    if not df_trend.empty:
        df_trend["day_local"] = pd.to_datetime(df_trend["DAY_LOCAL"])
        y_max = float(df_trend["DAILY_AVG_RMS"].max()) * 1.1

        trend_rules = pd.DataFrame([
            {"y": THRESHOLDS["vib_zone_d"], "label": "Zone D",
             "color": COLORS["bad"]},
            {"y": THRESHOLDS["vib_zone_c"], "label": "Zone C",
             "color": COLORS["warn"]},
        ])

        daily_line = (
            alt.Chart(df_trend)
            .mark_line(strokeWidth=1.5, opacity=0.45, strokeDash=[4, 2])
            .encode(
                x=alt.X("day_local:T", axis=alt.Axis(title="Date (GMT+7)")),
                y=alt.Y("DAILY_AVG_RMS:Q",
                        scale=alt.Scale(domain=[0, y_max]),
                        axis=alt.Axis(title="Avg RMS Velocity (mm/s)")),
                color=alt.Color(
                    "ASSET:N",
                    scale=alt.Scale(
                        domain=["motor_02", "motor_01"],
                        range=[COLORS["bad"], COLORS["good"]],
                    ),
                    legend=None,
                ),
                tooltip=[
                    alt.Tooltip("ASSET:N", title="Motor"),
                    alt.Tooltip("day_local:T", title="Date"),
                    alt.Tooltip("DAILY_AVG_RMS:Q", title="Daily Avg RMS", format=".3f"),
                ],
            )
        )

        rolling_line = (
            alt.Chart(df_trend)
            .mark_line(strokeWidth=2.5)
            .encode(
                x=alt.X("day_local:T"),
                y=alt.Y("ROLLING_7DAY_AVG_RMS:Q"),
                color=alt.Color(
                    "ASSET:N",
                    scale=alt.Scale(
                        domain=["motor_02", "motor_01"],
                        range=[COLORS["bad"], COLORS["good"]],
                    ),
                    legend=alt.Legend(title="Motor (7d avg)"),
                ),
                tooltip=[
                    alt.Tooltip("ASSET:N", title="Motor"),
                    alt.Tooltip("day_local:T", title="Date"),
                    alt.Tooltip("ROLLING_7DAY_AVG_RMS:Q", title="7-Day Avg RMS", format=".3f"),
                ],
            )
        )

        threshold_lines = (
            alt.Chart(trend_rules)
            .mark_rule(strokeDash=[6, 3], strokeWidth=1.5)
            .encode(
                y=alt.Y("y:Q"),
                color=alt.Color(
                    "color:N",
                    scale=alt.Scale(domain=trend_rules["color"].tolist(),
                                    range=trend_rules["color"].tolist()),
                    legend=None,
                ),
            )
        )

        st.altair_chart(
            (daily_line + rolling_line + threshold_lines)
            .properties(title="RMS Velocity Trend — Daily + 7-Day Rolling Average"),
            use_container_width=True,
        )
        st.caption("Solid = 7-day rolling avg · Faint dashed = daily · Horizontal lines = Zone C/D thresholds")
    else:
        st.info("No trend data available.")

    with st.expander("📖 ISO 10816 Zone Reference"):
        st.markdown("""
| Zone | RMS Range | Meaning | Action |
|------|-----------|---------|--------|
| **A** | < 1.8 mm/s | New/recently overhauled machine | ✅ None |
| **B** | 1.8 – 4.5 mm/s | Acceptable for long-term operation | ✅ Monitor normally |
| **C** | 4.5 – 11.2 mm/s | Marginal — tolerable short-term | ⚠️ Schedule inspection |
| **D** | > 11.2 mm/s | Dangerous — damage may occur | 🔴 Stop and inspect now |

*Standard: ISO 10816-3 for industrial machines with power > 15 kW.*
        """)

    # ── All motors summary table ─────────────────────────────────────────────
    st.subheader("All Motors")

    if not df_vib.empty:
        df_v = df_vib[["ASSET", "DOMINANT_ZONE", "AVG_RMS", "MAX_RMS",
                        "AVG_RPM", "AVG_TEMP_C", "AVG_CREST"]].copy()
        df_v.columns = ["Motor", "Zone", "Avg RMS (mm/s)", "Max RMS (mm/s)",
                        "Avg RPM", "Avg Temp (°C)", "Avg Crest Factor"]
        df_v.insert(1, "Status",
                    df_v["Zone"].apply(lambda z: status_icon(ZONE_STATUS.get(z, "bad"))))
        st.dataframe(df_v, use_container_width=True, hide_index=True)


# ════════════════════════════════════════════════════════════════════════════
# TAB 3 — ENERGY
# ════════════════════════════════════════════════════════════════════════════
with tab_energy:

    if df_energy_floor.empty or df_energy_wdwe.empty:
        st.info("Energy data not yet available — run the Silver and Gold energy pipelines first.")
    else:
        # ── 3a: kWh per floor ───────────────────────────────────────────────
        st.subheader("Energy by Floor  (Q3)")

        floor_cols = st.columns(len(df_energy_floor))
        for i, row in df_energy_floor.iterrows():
            pf_status = get_status(float(row["AVG_PF"]), 0.95, 0.85, higher_is_better=True)
            with floor_cols[i]:
                st.metric(
                    label=f"Floor {int(row['FLOOR_NUM'])} ({row['ASSET']})",
                    value=f"{int(row['TOTAL_KWH']):,} kWh",
                    delta=f"฿{int(row['TOTAL_COST_BAHT']):,}",
                )
                st.caption(f"Avg PF: {status_icon(pf_status)} {float(row['AVG_PF']):.3f}")

        # Bar chart — kWh per floor
        floor_chart_df = df_energy_floor[["ASSET", "PEAK_KWH", "OFFPEAK_KWH"]].copy()
        floor_chart_df.columns = ["Floor", "Peak kWh", "Off-Peak kWh"]

        stacked_energy = []
        for _, row in floor_chart_df.iterrows():
            stacked_energy += [
                {"Floor": row["Floor"], "Period": "Peak",     "kWh": float(row["Peak kWh"])},
                {"Floor": row["Floor"], "Period": "Off-Peak", "kWh": float(row["Off-Peak kWh"])},
            ]

        stacked_energy_df = pd.DataFrame(stacked_energy)
        energy_bar = (
            alt.Chart(stacked_energy_df)
            .mark_bar()
            .encode(
                x=alt.X("Floor:N", axis=alt.Axis(labelAngle=0, title=None)),
                y=alt.Y("kWh:Q", axis=alt.Axis(title="kWh")),
                color=alt.Color(
                    "Period:N",
                    scale=alt.Scale(
                        domain=["Peak", "Off-Peak"],
                        range=[COLORS["bad"], COLORS["neutral"]],
                    ),
                    legend=alt.Legend(title="Tariff Period"),
                ),
                tooltip=[
                    alt.Tooltip("Floor:N"),
                    alt.Tooltip("Period:N"),
                    alt.Tooltip("kWh:Q", format=",.0f"),
                ],
            )
            .properties(title="Total kWh by Floor — Peak vs Off-Peak")
        )
        st.altair_chart(energy_bar, use_container_width=True)

        # ── 3b: Weekday vs Weekend  (Q6) ────────────────────────────────────
        st.subheader("Weekday vs Weekend  (Q6)")

        wd_row = df_energy_wdwe[df_energy_wdwe["IS_WEEKEND"] == False]
        we_row = df_energy_wdwe[df_energy_wdwe["IS_WEEKEND"] == True]

        avg_wd = float(wd_row["AVG_DAILY_KWH"].iloc[0]) if not wd_row.empty else 0
        avg_we = float(we_row["AVG_DAILY_KWH"].iloc[0]) if not we_row.empty else 0
        pct_diff = ((avg_wd - avg_we) / avg_wd * 100) if avg_wd > 0 else 0

        col_wd, col_we, col_diff = st.columns(3)
        with col_wd:
            st.metric("Avg Weekday (kWh)", f"{avg_wd:,.0f}",
                      delta=f"฿{int(wd_row['AVG_DAILY_COST_BAHT'].iloc[0]):,} avg/day" if not wd_row.empty else "")
        with col_we:
            st.metric("Avg Weekend (kWh)", f"{avg_we:,.0f}",
                      delta=f"฿{int(we_row['AVG_DAILY_COST_BAHT'].iloc[0]):,} avg/day" if not we_row.empty else "")
        with col_diff:
            st.metric("Weekend Reduction", f"{pct_diff:.1f}%",
                      delta="vs Weekday", delta_color="normal")

        # ── 3c: Daily trend ──────────────────────────────────────────────────
        if not df_energy_trend.empty:
            st.subheader("Daily Energy Trend — Whole Plant (MAIN-MDB)")

            df_energy_trend["day_local"] = pd.to_datetime(df_energy_trend["DAY_LOCAL"])
            df_energy_trend["Day Type"] = df_energy_trend["IS_WEEKEND"].apply(
                lambda x: "Weekend" if x else "Weekday"
            )

            energy_trend_chart = (
                alt.Chart(df_energy_trend)
                .mark_bar()
                .encode(
                    x=alt.X("day_local:T", axis=alt.Axis(title="Date (GMT+7)")),
                    y=alt.Y("total_kwh:Q", axis=alt.Axis(title="Daily kWh")),
                    color=alt.Color(
                        "Day Type:N",
                        scale=alt.Scale(
                            domain=["Weekday", "Weekend"],
                            range=[COLORS["neutral"], COLORS["muted"]],
                        ),
                        legend=alt.Legend(title="Day Type"),
                    ),
                    tooltip=[
                        alt.Tooltip("day_local:T", title="Date"),
                        alt.Tooltip("total_kwh:Q", title="kWh", format=",.0f"),
                        alt.Tooltip("cost_baht:Q", title="Cost (฿)", format=",.0f"),
                        alt.Tooltip("Day Type:N"),
                    ],
                )
                .properties(title="Daily kWh — Weekday vs Weekend")
            )
            st.altair_chart(energy_trend_chart, use_container_width=True)
            st.caption("Colored by day type · Hover for cost in ฿")

        # ── 3d: Power factor table ───────────────────────────────────────────
        st.subheader("Power Factor by Floor")
        st.caption("Flag: avg PF < 0.85 may incur demand charges")

        if not df_energy_floor.empty:
            pf_df = df_energy_floor[["ASSET", "AVG_PF", "MIN_PF", "LOW_PF_HOURS"]].copy()
            pf_df.columns = ["Meter", "Avg PF", "Min PF", "Hours PF<0.85"]
            pf_df.insert(
                1, "Status",
                pf_df["Avg PF"].apply(
                    lambda v: status_icon(get_status(v, 0.95, 0.85))
                )
            )
            st.dataframe(pf_df, use_container_width=True, hide_index=True)


# ── Footer ───────────────────────────────────────────────────────────────────
st.divider()
st.caption(f"DE Challenge 2026 · Refreshed: {str(last_refresh)[:16]}")
