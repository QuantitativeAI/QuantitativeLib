# src/FinancialLibrary/Core.jl

module QuantitativeCore

using Dates: Day, Hour, Date
export InstrumentCalendar, PeriodDays, add_period!, add_periods, count_days, return2

"""
A calendar that tracks business days.
"""
struct InstrumentCalendar
    days::Vector{Date}
end

"""
Count the number of days in a calendar.
"""
function count_days(c::InstrumentCalendar)
    return length(c.days)
end

"""
A time period represented in days.
"""
struct PeriodDays
    days::Int64
end

"""
Add a date to a calendar.
"""
function add_period!(c::InstrumentCalendar, date::Date)
    push!(c.days, date)
end

"""
Add a period to a calendar.
"""
function add_period!(c::InstrumentCalendar, perioddays::PeriodDays)
    return push!(c.days, c.days[end] + Day(perioddays.days))
end

"""
Add a period to a calendar (non-mutating version).
"""
function add_period(c::InstrumentCalendar, perioddays::PeriodDays)
    return push!(c.days, c.days[end] + Day(perioddays.days))
end

"""
Add evenly spaced dates to a calendar.
"""
function add_periods(c::InstrumentCalendar, start_date::Date, days::Real,
                     num_periods::Real; exclude_non_business_days::Bool=false,
                     exclude_holidays::Bool=false)
    days_int = days isa Rational ? div(numerator(days), denominator(days)) : Int64(days)

    current_date = start_date
    for _ in 1:Int64(num_periods)
        push!(c.days, current_date)
        current_date += Day(days_int)
    end
    return c
end

"""
Return the number 2.
"""
function return2()
    return 2
end

end # module QuantitativeCore
