#' Load ensemble forecast data
#'
#' Loads in ensemble forecast data into the form: [day x issue x step x member]
#' Also generates a list of validtime timestamps
#'
#' If input file is in Maxar form, assumes a NETCDF file of the dimensions: [Day
#' x Hour x Site x Lead time x member] Maxar data can be loaded to either match
#' the form above or in a "rolling" format over the course of the year in the
#' form [1 x 1 x all steps x member] to make annual average metrics easier
#'
#' If input file in in ECMWF format, assumes a NETCDF file of the dimensions:
#' [day x issue x step x member]
#'
#' @param fname file name
#' @param members A vector of member indices
#' @param site Site index
#' @param metadata Metadata list including date end, temporal parameters,
#'   time-steps per day, rolling or not, etc.
#' @param date_start Timestamp
#' @param ... Additional parameters to load-in subfunctions
#' @return A list of data=[day x issue x step x member] matrix and issuetime=a
#'   vector of POSIXct timestamps
#' @export
get_forecast_data <- function(fname, members, site, metadata, date_start, ...) {

  if (metadata$is_rolling) {
    ensemble_issue_times <- date_start
  } else {
    # All issue times in the data set, which may include some training data
    ensemble_issue_times <- seq(from=date_start, to=metadata$date_last_valid,
                                by=paste(metadata$update_rate, "hours"))
  }

  # Open file
  nc <- ncdf4::nc_open(fname)

  data <- tryCatch({
    # Is this Maxar's format?
    if (all(names(nc$dim)==c("lon",  "lat",  "lev",  "time", "ens" ))){
      data <- get_maxar_ensemble(nc, members, site, metadata, ensemble_issue_times, ...)
    } else stop("Unrecognized forecast file format; ECMWF format not implemented")
    # TODO Megan to add ECMWF option
  },  finally = {
    # Close the file!
    ncdf4::nc_close(nc)
  })

  return(list(data=data, issuetime=ensemble_issue_times))
}

#' Subfunction to load in ECMWF data
#'
#' Loads in ensemble forecast data into the form: [day x issue x step x member]
#' If input file is in Maxar form, assumes a NETCDF file of the dimensions: [Day
#' x Hour x Site x Lead time x member] Maxar data can be loaded to either match
#' the form above or in a "rolling" format over the course of the year in the
#' form [1 x 1 x all steps x member] to make annual average metrics easier
#' @param nc An open NetCDF object
#' @param members A vector of member indices
#' @param site Site index
#' @param metadata Metadata list including date end, temporal parameters,
#'   time-steps per day, rolling or not, etc.
#' @param ensemble_issue_times A sequence of lubridate issue times
#' @param vname NetCDF variable name
#' @param truncate Boolean: Whether or not to truncate the forecasts at the site
#'   maximum power
#' @param date_data_start A lubridate: Date of first day in file
#' @param AC_rating AC power rating
get_maxar_ensemble <- function(nc, members, site, metadata, ensemble_issue_times,
                           vname="powernew", truncate=T,
                           date_data_start=lubridate::ymd(20160101),
                           AC_rating=NULL) {

  check_maxar_parameters(nc, metadata, site)

  if (truncate & is.null(AC_rating)) stop("Site maximum power required to truncate forecasts.")

  start_day <- get_start_day(date_data_start, ensemble_issue_times[[1]])

  if (metadata$is_rolling) {

    ndays <- get_ndays(ensemble_issue_times[[1]], metadata$date_last_valid)
    dim_counts <- c(ndays, metadata$ts_per_day, 1, 1, 1)

    # Get a matrix for this member, site, and lead time
    member_data <- function(member) {
      dim_starts <- c(start_day,1, site, metadata$lead_time, member)
      return(as.vector(t(ncdf4::ncvar_get(nc, varid=vname,
                                          start=dim_starts, count=dim_counts))))
    }

    # Get a [time x member] matrix at this site
    # (time is rolling along day, hour)
    data <- sapply(members, FUN = member_data, simplify ="array")
    if (truncate) {
      data[which(data > AC_rating)] <- AC_rating
    }

    # Reformat to [day x issue x step x member] format, but use
    # only a single day/issue time so that metrics for entire
    # year can be calculated all at once
    data <- array(data, dim=c(1, ndays*metadata$ts_per_day, length(members)))
  } else {

    ndays <- ceiling(length(ensemble_issue_times)/(24/metadata$update_rate))

    tictoc::tic("Ensemble load-in time along the diagonal")
    # Get the minimum rectangle of data from the NetCDF that contains the desired data,
    # to be extracted along the diagonals of the matrix
    dim_counts <- c(ndays, metadata$ts_per_day, 1, metadata$horizon, max(members))
    dim_starts <- c(start_day, 1, site, metadata$lead_time, 1)
    # [days x hours x lead time x member]
    data_rectangle <- array(ncdf4::ncvar_get(nc, varid=vname, start=dim_starts, count=dim_counts),
                            dim=c(ndays, metadata$ts_per_day, metadata$horizon, max(members)))

    data <- sapply(members, FUN=get_maxar_data_by_issue, data_rectangle=data_rectangle,
                   ensemble_issue_times=ensemble_issue_times, metadata=metadata, simplify="array")
    tictoc::toc()

    # [step x issue (rolling) x member] to [issue (rolling) x step x member]
    data <- aperm(data, perm=c(2,1,3))
  }
  return(data)
}

#' Subfunction to get single data point by issue and horizon
#'
#' Presumes 1-hour resolution of indices in data_rectangle
#' @param h Horizon index
#' @param issue A lubridate: issue time and hour
#' @param member Member index
#' @param data_rectangle Array of data from the NetCDF file
#' @param date_start A lubridate: Start date of data to load
#' @param metadata Metadata list including date end, temporal parameters,
#'   time-steps per day, rolling or not, etc.
#' @keywords internal
get_maxar_data_by_horizon <- function(h, issue, member, data_rectangle,
                                      date_start, metadata) {

  return(data_rectangle[get_ndays(date_start, issue) + floor(h/metadata$ts_per_day),
                        (lubridate::hour(issue) + metadata$lead_time + h -2 )%%metadata$ts_per_day + 1,
                        h, member])
}

#' Subfunction to get diagonal data by issue time
#'
#' @param member Member index
#' @param data_rectangle Array of data from the NetCDF file
#' @param ensemble_issue_times A sequence of lubridate issue times
#' @param metadata Metadata list including date end, temporal parameters,
#'   time-steps per day, rolling or not, etc.
#' @keywords internal
get_maxar_data_by_issue <- function(member, data_rectangle,
                                    ensemble_issue_times, metadata) {
  return(sapply(as.list(ensemble_issue_times),
                FUN = function(issue, member) {sapply(1:metadata$horizon,
                                                      FUN=get_maxar_data_by_horizon,
                                                      issue=issue, member=member,
                                                      data_rectangle=data_rectangle,
                                                      date_start=ensemble_issue_times[[1]],
                                                      metadata=metadata)},
                member=member, simplify="array"))
}

get_ecmwf_data <- function() {
  # TODO Megan to implement
  stop("Not implemented")
}

#' Subfunction to error-check temporal parameters for Maxar load-in
#'
#' @param nc An open NetCDF object
#' @param metadata Metadata list including date end, temporal parameters,
#'   time-steps per day, rolling or not, etc.
#' @param site Site index
check_maxar_parameters <- function(nc, metadata, site) {
  if (metadata$update_rate < 1 || metadata$update_rate%%1!=0) {stop("Update rate must be hourly, by at least 1 hour")}
  if (metadata$resolution !=1) stop("Maxar lookup function assumes resolution of 1 hour.")
  if (metadata$is_rolling) {
    if (metadata$horizon != metadata$update_rate) stop("Use equal horizon and update rate for rolling forecast.")
    ndays <- get_ndays(metadata$date_first_valid, metadata$date_last_valid)
    if (metadata$horizon != ndays*metadata$ts_per_day) stop("Horizon must be consistent with start/end dates for rolling forecast.")
  } else {
    if (metadata$horizon%%metadata$resolution!=0) stop("Horizon must be a multiple of resolution")
    if (metadata$horizon > nc$dim[[4]]$len) stop("Horizon cannot be longer than available lead times in Maxar matrix")
  }
  if (!(site %in% nc$dim[[3]]$vals)) stop("Site index not valid")
}

#' Get a vector of telemetry data
#'
#' Selects either Maxar or NSRDB format and loads data vector
#' Time-point selection is a consecutive sequence
#' @param fname file name
#' @param site Site index
#' @param metadata Metadata list including date end, temporal parameters,
#'   time-steps per day, rolling or not, etc.
#' @param date_start A lubridate: Start date of data to load
#' @return A list of data=vector of telemetry and validtime=vector of POSIXct times
#' @export
get_telemetry_data <- function(fname, site, metadata, date_start, ...) {

  # Open file
  nc <- ncdf4::nc_open(fname)

  data <- tryCatch({
    # Is this Maxar's format?
    if (all(names(nc$dim)==c('Day', 'Hour', 'SiteID'))){
      data <- get_maxar_telemetry(nc, site, metadata, date_start, ...)
    } else stop("Unrecognized forecast file format; NSRDB format not implemented")
    # TODO Megan to add NSRDB option
  },  finally = {
    # Close the file!
    ncdf4::nc_close(nc)
  })

  timestamps <- seq(date_start, length.out = length(data),
                              by = paste(metadata$resolution, "hour"))

  return(list(data=data, validtime=timestamps))
}

#' Load data from a NETCDF file of telemetry
#'
#' Assumed file dimensions: Day x Hour x Site
#' Time-point selection is a consecutive sequence
#' @param nc Open NetCDF file
#' @param site Site index
#' @param metadata Metadata list including date end, temporal parameters,
#'   time-steps per day, rolling or not, etc.
#' @param date_start A lubridate: Start date of data to load
#' @param date_data_start A lubridate: Date of first day in file
#' @param vname NetCDF variable name
#' @return A vector of telemetry
#' @export
get_maxar_telemetry <- function(nc, site, metadata, date_start,
                                date_data_start=lubridate::ymd(20160101),
                                vname="hsl_power") {

  # Calculate netcdf date constants
  ndays <- get_ndays(date_start, metadata$date_last_valid)
  start_day <- get_start_day(date_data_start, date_start)
  dim_counts <- c(ndays, metadata$ts_per_day, 1)

  data <- ncdf4::ncvar_get(nc, varid=vname, start=c(start_day,1,site), count=dim_counts)
  data <- as.vector(t(data))[seq(hour(date_start)+1,
                                 length.out=interval(date_start, metadata$date_last_valid)/hours(metadata$resolution)+1)]

  return(data)
}

#' Calculate number of days in the sequence
#' @param date_start A lubridate: Start date of data to load
#' @param date_end A lubridate: End date of data to load
#' @return Number of days in requested data sequence
#' @export
get_ndays <- function(date_start,date_end) {
  floor(lubridate::interval(date_start, date_end)/days(1) + 1)
}

#' Calculate start day's index since the beginning of data availability
#' @param date_data_start A lubridate: Date of first day in file
#' @param date_start A lubridate: Start date of data to load
#' @return Index number of first requested day
#' @export
get_start_day <- function(date_data_start, date_start){
  floor(lubridate::interval(date_data_start, date_start)/days(1) + 1)
}

#' Translate telemetry valid time to ensemble issue/step indices
#'
#' @param valid A POSIXct timestamp of valid time
#' @param metadata A data.frame of forecast parameters
#' @param ensemble A list of data=[issue x step x member] array of all
#'   ensemble data (historical + test) and issuetime=vector of POSIXct time
#'   stamps
#' @param issue (optional) A POSIXct timestamp of issue time, defaults to most
#'   recent forecast
#' @return c(issue, step) indices of the ensemble$data vector
#' @export
valid_2_issue_index <- function(valid, metadata, ensemble, issue=NULL) {
  lead_time <- ifelse(metadata$is_rolling, 0, metadata$lead_time)
  # Find timestamp of most recent issue
  if (is.null(issue)) {
    issue_index <- max(which(ensemble$issuetime <=
                               (valid-lubridate::hours(lead_time))))
    issue <- ensemble$issuetime[issue_index]
  } else {
    issue_index <- which(issue == ensemble$issuetime)
  }
  step_index <- (valid - issue - lubridate::dhours(lead_time))/
    lubridate::dhours(metadata$resolution) + 1
  return(c(issue_index, step_index))
}

#' Translate ensemble issue time and step to telemetry valid time index
#'
#' @param issue A POSIXct timestamp of issue time
#' @param step Index of forecast step in this run
#' @param metadata A data.frame of forecast parameters
#' @param telemetry A list of data=vector of telemetry and validtime=vector of
#'   POSIXct times
#' @return an index of the telemetry$data vector
#' @export
issue_2_valid_index <- function(issue, step, metadata, telemetry) {
  if (step < 1) stop("Step must be at least 1")
  lead_time <- ifelse(metadata$is_rolling, 0, metadata$lead_time)
  which(issue + lubridate::hours(lead_time + (step-1)*metadata$resolution)==
          telemetry$validtime)
}

#' Subset ensemble data to get BMA/EMOS training data
#'
#' This function will need to be expanded for full functionality of non-rolling forecasts
#'
#' @param time_idx_train Vector of time-point indices, relative to telemetry's valid times
#' @param ensemble A list of data=[issue x step x member] array of all
#'   ensemble data (historical + test) and issuetime=vector of POSIXct time
#'   stamps
#' @param metadata A data.frame of forecast parameters
#' @export
get_training_ensemble_from_validtimes <- function(time_idx_train, ensemble, metadata) {
  if (metadata$is_rolling) {
    # ensemble sizing is [1 x all steps x member]
    return(ensemble$data[1, time_idx_train, ])
  } else {
    stop("Not implemented yet")
  }
}