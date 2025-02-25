library(tidyverse)
library(tidycensus)
library(haven)
library(here)
library(sf)
library(tigris)
library(urbnthemes)
library(Cairo)
library(patchwork)
library(urbnmapr)
library (tigris)
library(censusapi)
library(forcats)
library(gridExtra)
library(scales)
library(extrafont)
source("routing/analysis_functions.R")
set_urbn_defaults(style = "map")

# Read in and row bind routing data #
routes_transit <- read_csv(here("routing/data", "all_routes_transit_final.csv"),
                   col_types = c("geoid_start" = "character",
                                 "geoid_end" = "character",
                                 "date" = "character")) %>%
  mutate(mode = "TRANSIT")

routes_car <- read_csv(here("routing/data", "all_routes_car_final.csv"),
                           col_types = c("geoid_start" = "character",
                                         "geoid_end" = "character")) 

routes_car_rush <- routes_car %>%
  # calculate adjusted duration by multiplying car trips by the 
  # 2019 ratio of INRIX off-peak speed (32) and peak speed (18) for Washington DC
  # https://inrix.com/scorecard-city/?city=Washington%20DC&index=89
  mutate(adj_duration = adj_duration * 1.78,
         date = "2021-09-15") %>%
  select(-departure_time)

routes_car_wknd <- routes_car %>%
  mutate(date = "2021-09-19") %>%
  select(-departure_time)
  

routes <- rbind(routes_car_rush, routes_car_wknd, routes_transit) 

# Read in ACS Data #
acs <- read_process_acs()

# reshape wide to make unit of analysis origin-destination-date 
routes_wide <- routes %>%
  select(geoid_end, geoid_start, adj_duration, mode, date) %>%
  pivot_wider(id_cols = c(geoid_start, geoid_end, date),
              names_from = mode, 
              values_from = adj_duration)

# set route time within same tract as 0 for all modes
routes_self_wkdy <- tibble(
  geoid_start = acs$GEOID,
  geoid_end = acs$GEOID,
  CAR = 0,
  TRANSIT = 0,
  date = "2021-09-15"
  
)

routes_self_wknd <- tibble(
  geoid_start = acs$GEOID,
  geoid_end = acs$GEOID,
  CAR = 0,
  TRANSIT = 0,
  date = "2021-09-19"
  
)

# combine all routing data
routes_wide <- rbind(routes_wide, routes_self_wkdy, routes_self_wknd)

routes_acs <- routes_wide %>%
  left_join(acs, by = c("geoid_start" = "GEOID")) %>%
  mutate(CAR = as.numeric(CAR),
         TRANSIT = as.numeric(TRANSIT),
         # weights car and transit time by percent of adults with no access to a car
         wt_duration = CAR * (1 - pct_no_car/100) + TRANSIT * (pct_no_car/100),
         # weights car and transit time by percent of adults who commute by car to work
         wt_duration_com = CAR * pct_car_commute/100 + TRANSIT * (1 - pct_car_commute/100))

# read summer food sites and child-serving sites excluded from  final food data file
sfs_sites <- read_csv(here("Food site data", "Food_retailers_TRANSPORT.csv")) %>%
  filter(sfsp == 1 | restrictions == "Serving children only" ) %>%
  mutate(weekends = as.character(weekends))

# create dataframe of all food sites and variables for sites that meet different conditions of interest
food_sites <- read_csv(here("Final food data", "Food_retailers_TRANSPORT.csv")) %>%
  #Exclude food sites that are available by appointment
  filter(is.na(frequency_visit) | frequency_visit != "Other frequency",
         # exclude food sites not in Arlington County
         !zip_code %in% c(22306, 22044),
         !location_address %in% c("3159 Row St.", "3305 Glen Carlyn Rd"),
         # exclude food sites serving children to avoid double counting with sfs_sites
         (is.na(restrictions) | restrictions != "Serving children only")) %>%
  bind_rows(sfs_sites) %>%
  filter(!is.na(latitude)) %>%
  st_as_sf(coords = c("longitude", "latitude")) %>%
  st_set_crs(4269) %>%
  mutate(is_snap = case_when(location_type == "SNAP-retailer" ~ 1,
                             T ~ 0),
         is_charitable = case_when(location_type == "Charitable food-site" ~ 1,
                                   T ~ 0),
         char_open_all = case_when((restrictions == "Open to all" & 
                                      year_round == "Open year-round") ~ 1,
                                   T ~ 0),
         char_open_flexible = case_when((restrictions == "Open to all" & 
                                      year_round == "Open year-round" &
                                        (weekends == "Yes"| open_afterhrs == "Open at or after 5:00 PM") ) ~ 1,
                                   T ~ 0),
         char_open_flexible_weekly = case_when((restrictions == "Open to all" & 
                                           year_round == "Open year-round" &
                                             frequency_visit == "Weekly or more frequent" &
                                           (weekends == "Yes"| open_afterhrs == "Open at or after 5:00 PM") ) ~ 1,
                                        T ~ 0),
         char_open_weekly = case_when((restrictions == "Open to all" & 
                                         frequency_visit == "Weekly or more frequent" &
                                         year_round == "Open year-round") ~ 1,
                                      T ~ 0),
         char_child_all = case_when(restrictions == "Serving children only" | sfsp == 1~ 1,
                                    T ~ 0),
         char_child_weekly = case_when(((restrictions == "Serving children only" | sfsp == 1) &
                                          frequency_visit == "Weekly or more frequent") ~ 1,
                                       T ~ 0),
         char_sen_all = case_when(restrictions == "Serving elders only"~ 1,
                                  T ~ 0),
         char_sen_weekly = case_when((restrictions == "Serving elders only" &
                                        frequency_visit == "Weekly or more frequent") ~ 1,
                                     T ~ 0)
  )

va_tract <- tracts(state = "51")
# get road shapefle
road <- roads(state = "Virginia", county = "013")
tract_food <- st_join(va_tract, food_sites, join = st_intersects)

# count of food sites of each type in each tract
tract_food_count <- tract_food %>%
  select(-charitablefs) %>%
  group_by(GEOID) %>%
  summarise(across(c(starts_with("char"), is_snap, is_charitable),
               sum, na.rm = TRUE)
  )

# Number of tracts in Arlington County with a SNAP retailer in the tract
tract_food_count %>%
  filter(substr(GEOID, 1, 5) == "51013", is_snap > 0) %>%
  nrow()

# Number of tracts in Arlington County with a Charitable retailer in the tract
tract_food_count %>%
  filter(substr(GEOID, 1, 5) == "51013", is_charitable > 0) %>%
  nrow()

# Number of tracts in Arlington County with an Open Charitable retailer in the tract
tract_food_count %>%
  filter(substr(GEOID, 1, 5) == "51013", char_open_all > 0) %>%
  nrow()

# join count of food sites to routes and acs data
routes_all <- routes_acs %>%
  left_join(tract_food_count, by = c("geoid_end" = "GEOID"))

write_csv(routes_all, here("routing/data", "routes_all.csv"))

routes_all <- read_csv(here("routing/data", "routes_all.csv"),
                       col_types = c("geoid_start" = "character",
                                      "geoid_end" = "character",
                                      "date" = "character"))
# read in food insecurity data
fi <- read_csv(here("Final food data/ACS and FI-MFI", 
                    "FI_ACS_data.csv"),
               col_types = c("geoid" = "character")) %>%
  select(geoid, percent_food_insecure)


mfi <- read_csv(here("Final food data/ACS and FI-MFI", 
                     "MFI_ACS_data.csv"),
                col_types = c("geoid" = "character")) %>%
  select(geoid, percent_mfi = percent_food_insecure)

all_fi <- fi %>%
  left_join(mfi, by = "geoid") %>%
  # set at in the top quartile of tracts
  mutate(is_high_fi = ifelse(percent_food_insecure > .12, 1, 0),
         is_high_mfi = ifelse(percent_mfi > .12, 1, 0)) 

# define set of parameters for which we want to calculate time to closest food site
route_date <- c("2021-09-15", "2021-09-19")
food_type <- c("is_snap", "is_charitable", "char_open_all", "char_open_weekly",
               "char_sen_all", "char_sen_weekly", "char_child_all", "char_child_weekly",
               "char_open_flexible", "char_open_flexible_weekly")
dur_type <- c("wt_duration", "wt_duration_com", "TRANSIT")

ttc_params <- expand_grid(
  route_date = route_date,
  food_type = food_type,
  dur_type = dur_type
)

all_ttc <- pmap_dfr(ttc_params, 
                    travel_time_to_closest, 
                    all_data = routes_all,
                    fi_data = all_fi)


num_no_access_snap_20 <- all_ttc %>%
  filter(food_type == "is_snap", min_duration > 20) %>%
  group_by(dur_type, route_date) %>%
  summarise(count = n())

num_no_access_snap_15 <- all_ttc %>%
  filter(food_type == "is_snap", min_duration > 15) %>%
  group_by(dur_type, route_date) %>%
  summarise(count = n())

high_need_low_access <- all_ttc %>%
  group_by(food_type, dur_type, route_date) %>%
  summarise(high_need_low_access_15 = sum(high_need_low_access_snap_15, na.rm = TRUE),
            high_need_low_access_20 = sum(high_need_low_access_snap_20, na.rm = TRUE))

low_access <- all_ttc %>%
  mutate(over_15 = ifelse(min_duration > 15, 1, 0),
         over_20 = ifelse(min_duration > 20, 1, 0)) %>%
  group_by(food_type, dur_type, route_date) %>%
  summarise(low_access_15 = sum(over_15, na.rm = TRUE),
            low_access_20 = sum(over_20, na.rm = TRUE))

# define set of parameters for which we want to calculate number of food sites accessible
# within time threshold t
cwt_params <- expand_grid(
  route_date = route_date,
  food_type = food_type,
  dur_type = dur_type,
  t = c(15, 20)
)

all_cwt <- pmap_dfr(cwt_params, 
                    count_accessible_within_t, 
                    all_data = routes_all,
                    fi_data = all_fi)


count_snap <- all_cwt %>%
  filter(food_type == "is_snap", 
         time == 20) %>%
  filter(!geoid_start %in% c("51013103401","51013980200", "51013980100")) %>%
  group_by(route_date, dur_type) %>%
  summarise(min_count = min(count, na.rm = TRUE),
            max_count = max(count, na.rm = TRUE))




# Time to closest open/weekly charitable food location
map_char_ttc <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_open_all",
           dur_type == "wt_duration_com"),
  county_shp = acs,
  opp = "Open Charitable Food Location",
  need_var = "is_high_fi",
  dur_type = "Weighted Travel Time",
  road = road)

map_char_ttc_wkly <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_open_weekly",
           dur_type == "wt_duration_com"),
  county_shp = acs,
  opp = "Weekly Open Charitable Food Location",
  need_var = "is_high_fi",
  dur_type = "Weighted Travel Time",
  road = road)

map_char_ttc_transit <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_open_all",
           dur_type == "TRANSIT"),
  county_shp = acs,
  opp = "Open Charitable Food Location",
  need_var = "is_high_fi",
  dur_type = "Transit",
  road = road)

map_char_ttc_wkly_transit <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_open_weekly",
           dur_type == "TRANSIT"),
  county_shp = acs,
  opp = "Weekly Open Charitable Food Location",
  need_var = "is_high_fi",
  dur_type = "Transit",
  road = road)


# Map Access within 40-min round trip for different eligibility

map_char_access <- map_access_within_t(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type %in% c("char_open_all", "char_open_weekly", "char_open_flexible_weekly"),
           dur_type == "TRANSIT") %>%
    mutate(food_type = factor(case_when(food_type == "char_open_all" ~ "Open year-round,\nno eligibility requirements",
                                 food_type == "char_open_weekly" ~ "Open weekly year-round,\nno eligibility requirements",
                                 food_type == "char_open_flexible_weekly" ~ "Open weekly and non traditional hours\n year-round, no eligibility requirements"),
                              levels = c("Open year-round,\nno eligibility requirements", 
                                         "Open weekly year-round,\nno eligibility requirements",
                                         "Open weekly and non traditional hours\n year-round, no eligibility requirements"))
           ),
  county_shp = acs,
  opp = "charitable food locations",
  need_var = "is_high_fi",
  dur_type = "Transit",
  road = road, 
  t_limit = 40)


# Time to closest SNAP retailer
map_snap_ttc <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "is_snap",
           dur_type == "TRANSIT"),
  county_shp = acs,
  opp = "SNAP Retailer",
  need_var = "is_high_fi",
  dur_type = "Transit",
  road = road)

# Time to closest Senior Site, Highlight top tracts by num sen under fpl
map_char_sen_ttc <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_sen_all",
           dur_type == "wt_duration_com"),
  county_shp = acs,
  opp = "Open Charitable Food Location Seniors",
  need_var = "is_high_pov_senior",
  dur_type = "Weighted Travel Time",
  road = road)

map_char_sen_ttc_transit <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_sen_all",
           dur_type == "TRANSIT"),
  county_shp = acs,
  opp = "Open Charitable Food Location Seniors",
  need_var = "is_high_pov_senior",
  dur_type = "Transit",
  road = road)

# proportion of children in poverty in focus tracts/other tracts
# proportion of all children in poverty who live in focus tracts
acs %>% 
  group_by(is_high_pov_senior) %>% 
  summarize(count_sen_pov = sum(pov_seniors_total), 
            count_sen = sum(seniors_total)) %>%
  mutate(total_pct_pov = count_sen_pov/count_sen,
         pct_all_pov = count_sen_pov/sum(count_sen_pov))

# Time to closest child site, Highlight top tracts by num child under fpl
map_char_child_ttc <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_child_all",
           dur_type == "wt_duration_com"),
  county_shp = acs,
  opp = "Open Charitable Food Location Children",
  need_var = "is_high_pov_child",
  dur_type = "Weighted Travel Time",
  road = road)

ttc_high_pov_child = all_ttc %>% 
  filter(route_date == "2021-09-15", 
         food_type == "char_child_all",
         dur_type == "wt_duration_com") %>%
  left_join(acs, by = c("geoid_start" = "GEOID")) %>%
  filter(is_high_pov_child == 1)

map_char_child_ttc_transit <- map_time_to_closest(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_child_all",
           dur_type == "TRANSIT"),
  county_shp = acs,
  opp = "Open Charitable Food Location Children",
  need_var = "is_high_pov_child",
  dur_type = "Transit",
  road = road)

ttc_high_pov_child = all_ttc %>% 
  filter(route_date == "2021-09-15", 
         food_type == "char_child_all",
         dur_type == "TRANSIT") %>%
  left_join(acs, by = c("geoid_start" = "GEOID")) %>%
  filter(is_high_pov_child == 1)

# proportion of children in poverty in focus tracts/other tracts
# proportion of all children in poverty who live in focus tracts
acs %>% 
  group_by(is_high_pov_child) %>% 
  summarize(count_child_pov = sum(pov_children_total), 
            count_child = sum(children_total)) %>%
  mutate(total_pct_pov = count_child_pov/count_child,
         pct_all_pov = count_child_pov/sum(count_child_pov))

# Map number of retailers available within t minutes

map_count_snap <- map_count_within_t(
  count_within_t = all_cwt %>%
    filter(route_date == "2021-09-15", 
           food_type == "is_snap",
           dur_type == "wt_duration_com",
           time == 20),
  county_shp = acs,
  opp = "SNAP Retailers",
  need_var = "is_high_fi",
  dur_type = "Weighted Travel Time",
  road = road)

map_count_snap_transit <- map_count_within_t(
  count_within_t = all_cwt %>%
    filter(route_date == "2021-09-15", 
           food_type == "is_snap",
           dur_type == "TRANSIT",
           time == 20),
  county_shp = acs,
  opp = "SNAP Retailers",
  need_var = "is_high_fi",
  dur_type = "Transit",
  road = road)


map_count_char_open <- map_count_within_t(
  count_within_t = all_cwt %>%
    filter(route_date == "2021-09-15", 
           food_type == "char_open_all",
           dur_type == "wt_duration_com",
           time == 20),
  county_shp = acs,
  opp = "Open Charitable Food Locations",
  need_var = "is_high_fi",
  dur_type = "Weighted Travel Time",
  road = road)

map_count_char_open_transit <- map_count_within_t(
  count_within_t = all_cwt %>%
    filter(route_date == "2021-09-15", 
           food_type == "char_open_all",
           dur_type == "TRANSIT",
           time == 20),
  county_shp = acs,
  opp = "Open Charitable Food Locations",
  need_var = "is_high_fi",
  dur_type = "Transit",
  road = road)

# Racial Equity Analysis

race_bar_char_ttc_wkly <- make_bar_plot_race(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_open_weekly",
           dur_type == "wt_duration_com"),
  county_shp = acs,
  opp = "Weekly Open Charitable Food Location",
  dur_type = "Weighted Travel Time")

facet_map_char_week <- make_facet_map_race_avg(county_shp = acs, 
                        ttc = all_ttc %>% 
                          filter(route_date == "2021-09-15", 
                                 food_type == "char_open_weekly",
                                 dur_type == "wt_duration_com"), 
                        opp = "Weekly Open Charitable Food Location",
                        dur_type = "Weighted Travel Time",
                        road = road)

facet_scatter_char_week <- make_scatter_plot_race(county_shp = acs, 
                                               ttc = all_ttc %>% 
                                                 filter(route_date == "2021-09-15", 
                                                        food_type == "char_open_weekly",
                                                        dur_type == "wt_duration_com"), 
                                               opp = "Weekly Open Charitable Food Location",
                                               dur_type = "Weighted Travel Time")

race_bar_char_ttc_all <- make_bar_plot_race(
  ttc = all_ttc %>% 
    filter(route_date == "2021-09-15", 
           food_type == "char_open_all",
           dur_type == "wt_duration_com"),
  county_shp = acs,
  opp = "Open Charitable Food Location",
  dur_type = "Weighted Travel Time")

facet_map_char_all <- make_facet_map_race_avg(county_shp = acs, 
                                               ttc = all_ttc %>% 
                                                 filter(route_date == "2021-09-15", 
                                                        food_type == "char_open_all",
                                                        dur_type == "wt_duration_com"), 
                                               opp = "Open Charitable Food Location",
                                               dur_type = "Weighted Travel Time",
                                               road = road)

facet_scatter_char_all <- make_scatter_plot_race(county_shp = acs, 
                                                  ttc = all_ttc %>% 
                                                    filter(route_date == "2021-09-15", 
                                                           food_type == "char_open_all",
                                                           dur_type == "wt_duration_com"), 
                                                  opp = "Open Charitable Food Location",
                                                  dur_type = "Weighted Travel Time")

dot_density_map <- make_dot_density_race(acs)


# Map showing interview tracts
interview_tract_list <- c("51013102100", "51013102003",
                          "51013102200", "51013103300")
acs <- acs %>%
  mutate(is_interview_tract = factor(ifelse(GEOID %in% interview_tract_list, 1, 0)))

set_urbn_defaults(style = "map")
interview_map <- ggplot() +
  geom_sf(data = acs, mapping = aes(fill = is_interview_tract, 
                                    color = is_interview_tract),
          size = .6) +
  #add roads to map
  geom_sf(data = road,
          color="grey", fill="white", size=0.25, alpha =.5) +
  scale_fill_manual(values = c("#1696d2", "#73bfe2"),
                    guide = 'none') +
  scale_color_manual(values = c("grey", palette_urbn_main[["magenta"]]),
                     guide = 'none') 

ggsave(
  plot = interview_map,
  filename = here("routing/images", "interview_tract_map.pdf"),
  height = 6, width = 10, units = "in", dpi = 500, 
  device = cairo_pdf)
  
acs_pov = get_acs(state = "51", county = "013", geography = "county",
              variables = c(black = "B02001_003", 
                            white = "B02001_002", 
                                 total_pop = "B01003_001",
                                 hispanic = "B03003_003", 
                                 asian = "B02001_005", 
                                 total_pop_pov = "S1701_C01_001",
                                 pov_white = "S1701_C02_013",
                                 pov_black = "S1701_C02_014",
                                 pov_asian = "S1701_C02_016",
                                 pov_hisp = "S1701_C02_020"),
              output= "wide") %>%
  select(!ends_with("M")) %>%
  mutate(across(starts_with("pov"), ~.x/total_pop_povE, .names = "pct_{.col}"))
