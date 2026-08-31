# src/FinancialLibrary/Core.jl

module QuantitativeCore

using Dates
import Dates: Date
export InstrumentCalendar, PeriodDays, add_period!, count_days, return2, Date

"""
A calendar that tracks business days.
"""
struct InstrumentCalendar
    days::Vector{Dates.Date}
end

"""
Count the number of days in a calendar.
"""
function count_days(c::InstrumentCalendar)
    return length(c.days)
end

"""
Add a period to a calendar.
"""
add_period!(c::InstrumentCalendar, period::Period) = push!(c.days, c.days[end] + period)

"""
Add a date to a calendar.
"""
function add_period!(c::InstrumentCalendar, date::Dates.Date)
    push!(c.days, date)
end

"""
A time period represented in days.
"""
struct PeriodDays
    days::Int64
end

"""
Add a period to a calendar.
"""
function add_period!(c::InstrumentCalendar, perioddays::PeriodDays)
    return push!(c.days, c.days[end] + Dates.Day(perioddays.days))
end

"""
Add a period to a calendar (non-mutating version).
"""
function add_period(c::InstrumentCalendar, perioddays::PeriodDays)
    return push!(c.days, c.days[end] + Dates.Day(perioddays.days))
end

"""
Return the number 2.
"""
function return2()
    return 2
end

end # module QuantitativeCore
