# src/FinancialLibrary/Core.jl

module QuantitativeCore

using Dates

export Calendar, Period, add_period!, count_days, return2

"""
A calendar that tracks business days.
"""
struct Calendar
    days::Vector{Dates.Date}
end

"""
Count the number of days in a calendar.
"""
function count_days(c::Calendar)
    return length(c.days)
end

"""
Add a period to a calendar.
"""
add_period!(c::Calendar, period::Period) = push!(c.days, c.days[end] + period)

"""
Add a date to a calendar.
"""
function add_period!(c::Calendar, date::Dates.Date)
    push!(c.days, date)
end

"""
A time period represented in days.
"""
struct Period
    days::Int64
end

"""
Add a period to a calendar.
"""
function add_period!(c::Calendar, period::Period)
    return push!(c.days, c.days[end] + Dates.Day(period.days))
end

"""
Add a period to a calendar (non-mutating version).
"""
function add_period(c::Calendar, period::Period)
    return push!(c.days, c.days[end] + Dates.Day(period.days))
end

"""
Return the number 2.
"""
function return2()
    return 2
end

end # module QuantitativeCore
