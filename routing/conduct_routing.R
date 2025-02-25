library(opentripplanner)
library(tidyverse)
library(here)
library(parallel)
library(sf)
library(furrr)
library(testit)


make_config <- function(path_data, router_name){
  # Make router config with default parameters. You can edit these parameters if desired as described in 
  # (https://docs.ropensci.org/opentripplanner/articles/advanced_features.html#configuring-opentripplanner-1)
  # 
  router_config <- otp_make_config("router")
  router_config$routingDefaults$waitAtBeginningFactor <- 0.5
  assert("config is valid", otp_validate_config(router_config))
  otp_write_config(router_config,                
                   dir = path_data,
                   router = router_name)
}

build_graph <- function(path_otp, path_data, memory, router_name){
  # Because this is a large road network, my computer required more than the default 2GB of memory. 
  # I have it set to 8GB which worked on my Urban laptop. This will take a couple of minutes to run.
  # 
  if(!file.exists(paste(path_data, str_glue("graphs/{router_name}/Graph.obj"), sep = "/"))){
    log1 <- otp_build_graph(otp = path_otp, 
                            dir = path_data, 
                            memory = memory,
                            router = router_name)
  }
}


start_otp <- function(path_otp, path_data, memory, router_name){
  # Again, set the memory to 8GB for routing. This can take a little bit of time. 
  # It will open up a browser window with the routing interface. Create OTP connection object. 
  #  
  
  log2 <- otp_setup(otp = path_otp, 
                    dir = path_data, 
                    memory = memory,
                    router = router_name)
  otpcon <- otp_connect(timezone = "America/New_York",
                        router = router_name)
  
  return(otpcon)
}

create_graph_setup_otp <- function(path_data, path_otp, memory, router_name){
  # set up opentripplanner for routing
  make_config(path_data, router_name)
  build_graph(path_otp, path_data, memory, router_name)
  otpcon <- start_otp(path_otp, path_data, memory, router_name)
  
  return(otpcon)
}

create_otp_plan <- function(mode_out, from_place, to_places, from_id, departure_time, otp_connection){
  # Conducts batch routing for provided transportation mode transportation mode
  
  #Identifies number of cores for batch routing
  n_cores = detectCores() - 1
  if (mode_out == "TRANSIT") {
    mode_route <- c("WALK", "TRANSIT")
  } else {
    mode_route <- c("CAR")
  } 
  
  routes <- tryCatch(
    {routes <- otp_plan(otp_connection, 
                        fromPlace = from_place, 
                        toPlace = to_places,
                        fromID = from_id,
                        toID = to_places$geoid_end,
                        mode = mode_route,
                        get_geometry = FALSE, #can change to true if want geometry of driving route
                        numItineraries = 1, #only returns single fastest itinerary
                        ncores = n_cores,
                        date_time = departure_time)},
    error = function(err){
      routes <- tibble(
        duration = NA_real_, 
        distance = NA_real_, 
        from_geoid = from_id, 
        to_geoid = NA_character_
      )
      return(routes)
    }
  ) 
  
  
  if (!is.na(routes)){
    routes_out <- routes %>%
      select(duration, distance, geoid_start = fromPlace, geoid_end = toPlace, startTime) %>%
      group_by(geoid_start, geoid_end) %>%
      #duration value should be same across all legs
      mutate(
        startTime = as.POSIXct(startTime),
        start_wait = startTime - as.POSIXct(departure_time),
        adj_duration = duration + start_wait * 0.5
        ) %>%
      #convert seconds to minutes
      summarise(duration = round( max(duration, na.rm = TRUE)/60, 3), 
                adj_duration = round( max(adj_duration, na.rm = TRUE)/60, 3), 
                # convert meters to miles
                distance = round( sum(distance, na.rm = TRUE)*6.21371e-4, 3)) %>%
      mutate(mode = mode_out,
             departure_time = departure_time) 
    
    routes_out <- to_places %>%
      st_drop_geometry() %>%
      left_join(routes_out, by = "geoid_end") %>%
      replace_na(list(geoid_start = from_id,
                      mode = mode_out,
                      departure_time = departure_time))
  } else {
    # if no routes can be found for a given start point, will return one row with the following:
    routes_out <- tibble(
      duration = NA_real_, 
      adj_duration = NA_real_,
      distance = NA_real_, 
      geoid_start = from_id, 
      geoid_end = to_places$geoid_end,
      mode = mode_out,
      departure_time = departure_time
    )
  }
  
  
  return(routes_out)
}


batch_route <- function(df, 
                        otp_connection, 
                        departure_time,
                        mode){
  
  # Function to calculate a batch of driving routes between a single starting point (from_place) 
  # points to multiple destinations (to_places). Returns a dataframe with routing data including the following key fields:
  # duration (int): duration of the trip in seconds
  # distance (numeric): distance of the trip in meters
  # fromPlace (character): unique identifier for origin
  # toPlace (character): unique identifier for destination
  
  #INPUTS:
  # df (data.frame): dataframe with multiple origins and one destination.
  # otp_connection: otp connection object
  # dt (POSIX datetime): departure time of trip
  #RETURNS:
  # routes (data.frame): dataframe of route information
  
  # convert to sf dataframe for  batch routing  
  to_places <- df %>% 
    select(geoid_end, lat_end, lon_end) %>%
    st_as_sf(coords = c("lon_end", "lat_end"),
             crs = 4326)
  
  # because df has been split on tract, can select first start_lon, start_lat, and tract
  from_lon <- df %>%
    select(lon_start) %>%
    slice(1) %>%
    pull()
  
  from_lat <- df %>%
    select(lat_start) %>%
    slice(1) %>%
    pull()
  
  from_id <- df %>%
    select(geoid_start) %>%
    slice(1) %>%
    pull()
  
  #OTP wants coordinates as longitude, latitude
  from_place <- c(from_lon, from_lat)
  
  all_routes <- create_otp_plan(mode_out = mode,
                        from_place = from_place, 
                        to_places = to_places, 
                        from_id = from_id,
                        departure_time = departure_time,
                        otp_connection = otpcon)
  
  
  
  return(all_routes)
}

route_date <- function(date, df_list, otpcon, mode){
  #date (str):Form YYYY-MM-DD hh:mm:ss, e.g. "2019-06-15 8:00:00"
  
  dt <- as.POSIXct(strptime(date, "%Y-%m-%d %H:%M:%S"), tz = "America/New_York")
  
  # If a path cannot be found between the start and end point, the otp_plan will not return a row for that     
  # start/end pair. Therefore, the dataframe returned by this function may be smaller than the input dataframe.
  routes <- map_dfr(df_list, 
                    batch_route, 
                    otp_connection = otpcon, 
                    departure_time = dt, 
                    mode = mode)
  
  return(routes)
}

copy_road_transit_data <- function(router_name, osm_path){
  # copy files based on date
  files <- list.files(here("routing/data/gtfs-clean"))
  files_to_copy <- files[grep(router_name, files)]
  file.copy(from = file.path(here("routing/data/gtfs-clean"), files_to_copy),
            to = osm_path)
  
  file.copy(from = file.path(here("routing/data"), "osm_bounds.pbf"),
            to = osm_path)
}

df <- read_csv(here("routing/data", "route_pairs.csv"), 
               col_types = c("tract_str_start" = "character", 
                             "tract_str_end" = "character",
                             "geoid_end" = "character",
                             "geoid_start" = "character"),
               lazy = FALSE) %>%
  # remove routes where start and end point is the same, we assume
  # 0 time for these
  filter(geoid_start != geoid_end)




# sample three times within ten minutes before or after time
set.seed(1234)
sec_diff <- sample(-10:10, 3) * 60
date <- c("2021-09-15 17:30:00", "2021-09-19 14:30:00")
date_combo <- expand_grid(date, sec_diff)
all_dates <- unlist(pmap(date_combo, function(date, sec_diff) as.character(as.POSIXct(date) + sec_diff)))

## Create folder for OTP and its Data + Download OTP ##
path_data <- here("routing/otp")
dir.create(path_data)

# downloads open trip planner program
path_otp <- otp_dl_jar(path_data, cache =  FALSE)
dir.create(here("routing/otp/graphs"))

#create folder for data and graph for given state
osm_path <- here(str_glue("routing/otp/graphs/{router_name}"))
dir.create(osm_path)

#download road and transit data into folder for given state
router_name <-  "2021-09-15"
copy_road_transit_data(router_name, osm_path)

# Uses 8GB of memory
memory <- 12000

# set up otp by creating configuration file, building graph and starting otp
otpcon <- create_graph_setup_otp(path_data, path_otp, memory, router_name)

#split dataframe into a list of dataframes on start tract geoid
df_list <- split(df, f = df$geoid_start)

all_routes_transit <- map_dfr(all_dates, 
                              route_date, 
                              df_list = df_list, 
                              otpcon = otpcon,
                              mode = "TRANSIT")
                              
write_csv(all_routes_transit, here("routing/data", "all_routes_transit_raw.csv"))

all_routes_transit_avg <- all_routes_transit %>%
  mutate(date = substr(departure_time, 1, 10)) %>%
  group_by(geoid_start, geoid_end, date) %>%
  summarise(duration = mean(duration, na.rm = TRUE),
            adj_duration = mean(adj_duration, na.rm = TRUE),
            distance = mean(distance, na.rm = TRUE))

write_csv(all_routes_transit_avg, here("routing/data", "all_routes_transit_final.csv"))

all_routes_car <- route_date(date = "2021-09-15 17:30:00",
                             df_list = df_list, 
                             otpcon = otpcon,
                             mode = "CAR")

write_csv(all_routes_car, here("routing/data", "all_routes_car_final.csv"))


otp_stop(warn = FALSE)