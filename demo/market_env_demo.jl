# ─────────────────────────────────────────────
# Example Usage
# ─────────────────────────────────────────────

using Dates
using QuantitativeLib
using QuantitativeLib.Curves: make_curve, get_rate, get_discount_factor,
                             get_forward_rate, YieldCurve, DiscountCurve,
                             ForwardCurve, Linear, VolSurface, ZeroRate,
                             ForwardRate, interpolate_vol

as_of = Date(2024, 1, 15)

# ── Build a yield curve ──
dates_3m = [as_of + Month(3*i) for i in 1:8]       # 3M deposits
rates_3m = [0.0520, 0.0525, 0.0530, 0.0535, 0.0540, 0.0545, 0.0550, 0.0555]
yc = YieldCurve(make_curve(as_of, dates_3m, rates_3m, ZeroRate;
    currency = "USD", name = "USD_Swap_Curve", interp_method = Linear), :interpolation)

# ── Build a forward curve ──
dates_6m = [as_of + Month(6*i) for i in 1:8]
rates_6m = [0.0530, 0.0535, 0.0540, 0.0548, 0.0555, 0.0560, 0.0565, 0.0570]
fc_base = make_curve(as_of, dates_6m, rates_6m, ForwardRate;
    currency = "USD", name = "USD_6M_SOFR_Forward", interp_method = Linear)
fc = ForwardCurve(fc_base, "6M", "SOFR")

# ── Build a discount curve (OIS) ──
ois_dates = [as_of + Year(i) for i in 1:10]
ois_rates = [0.0500, 0.0505, 0.0510, 0.0515, 0.0520, 0.0525, 0.0530, 0.0535, 0.0540, 0.0545]
dc_base = make_curve(as_of, ois_dates, ois_rates, ZeroRate;
    currency = "USD", day_count = "ACT/360", name = "OIS_Discount", interp_method = Linear)
dc = DiscountCurve(dc_base, true)

# ── Build a vol surface ──
expiries = [0.25, 0.5, 1.0, 2.0, 3.0, 5.0]
moneyness_vals = [0.80, 0.90, 1.00, 1.10, 1.20]
vols = [0.20 0.21 0.22 0.23 0.24;
        0.19 0.20 0.21 0.22 0.23;
        0.18 0.19 0.20 0.21 0.22;
        0.17 0.18 0.19 0.20 0.21;
        0.16 0.17 0.18 0.19 0.20;
        0.15 0.16 0.17 0.18 0.19]
vs = VolSurface(as_of, expiries, moneyness_vals, vols, Linear([0.25, 0.5, 1.0], [0.20, 0.21, 0.22]), Linear([0.90, 1.00, 1.10], [0.20, 0.21, 0.22]),
                :implied_vol, :option, "USD")

# ── Query the curves ──
t = 1.5  # 1.5 years
zero_rate = get_rate(yc, t)
df = get_discount_factor(dc, t)
fwd = get_forward_rate(fc, 1.0, 2.0)

println("Zero rate at 1.5y: $(round(zero_rate * 100, digits=2))%")
println("Discount factor at 1.5y: $(round(df, digits=6))")
println("Forward rate 1y→2y: $(round(fwd * 100, digits=2))%")

# ── Vol surface lookup ──
vol_interp = interpolate_vol(vs)
println("Vol at expiry=2.0, moneyness=1.0: $(round(vol_interp(2.0, 1.0), digits=4))")
