# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# This script:
# calculates the counts for the flowchart in the manuscript
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Preliminaries ----

# import libraries
library(tidyverse)
library(glue)
library(here)

# load functions and paramters
source(here("analysis", "design.R"))
source(here("analysis", "functions", "utility.R"))
source(here("analysis", "functions", "fuzzy_join.R"))

# create output directories
outdir <- here("output", "report", "flowchart")
fs::dir_create(outdir)

# import flowchart for single trial cohort
data_singleeligible <- readr::read_rds(here("output", "single", "eligible", "data_singleeligible.rds")) %>%
  select(patient_id, vax1_date, vax1_type)

# define all flow categories for sequential trial cohorts
flow_categories <- tribble(
  ~crit, ~criteria,
  # those who are vaccinated with the brand on day 1 of recruitment
  "A", "vaccinated and unmatched",
  "B", "vaccinated and matched",
  # those who are vaccinated with the brand during the recruitment period but not on day 1
  "C", "unvaccinated and unmatched then vaccinated and unmatched",
  "D", "unvaccinated and unmatched then vaccinated and matched",
  "E", "unvaccinated and matched then vaccinated and unmatched",
  "F", "unvaccinated and matched then vaccinated and matched",
  # those who remain unvaccinated at the end of the recruitment period
  "G", "unvaccinated and unmatched",
  "H", "unvaccinated and matched",
  # those who are vaccinated with the other brand
  "I", "vaccinated with the other brand and matched as control"
) 

# define boxes for sequential trial flow
flow_boxes <- tribble(
  ~box_crit, ~box_descr,
  "ABCDEF", "Vaccinated with {brand} during recruitment period",
  "AC", "Vaccinated with {brand} during recruitment period, unmatched as treated, unmatched as control",
  "BDF", "Vaccinated with {brand} during recruitment period, matched as treated",
  "E", "Vaccinated with {brand} during recruitment period, matched as treated, matched as control",
  "F", "Vaccinated with {brand} during recruitment period, matched as treated, matched as control",
  "EFHI", "Unvaccinated, matched as control in {brand} trial",
  "GH", "Unvaccinated up to recruitment end",
  "G", "Unvaccinated up to recruitment end, unmatched as control",
  "H", "Unvaccinated up to recruitment end, matched as control in {brand} trial",
  "I", "Vaccinated with the other brand during recruitment period, matched as control"
)

# derive data for flowcharts with brands combined and specified
flowchart_matching_function <- function(brand) {
  
  # read data for eligible treated
  treated_eligible <- readr::read_rds(here("output", "sequential", "treated", "eligible", glue("flowchart_treatedeligible_{brand}_unrounded.rds"))) 
  
  # reshape so one row per patient, and logical columns to indicate if matched as treated, control or both
  data_matched <- readr::read_rds(here("output", "sequential", brand, "match", "data_matched.rds")) %>%
    select(patient_id, treated) %>%
    mutate(matched = 1) %>%
    pivot_wider(
      names_from = treated,
      values_from = matched
    ) %>%
    rename("treated" = "1", "control" = "0") 
  
  # categorise individuals
  data_match_flow  <- data_singleeligible %>%
    left_join(data_matched, by = "patient_id") %>%
    mutate(across(c(treated, control), ~ replace_na(.x, replace=FALSE))) %>%
    mutate(
      crit = case_when(
        # those who are vaccinated on day 1 of recruitment
        vax1_type == brand & vax1_date == study_dates[[brand]]$start_date & !control & !treated ~ "A",
        vax1_type == brand & vax1_date == study_dates[[brand]]$start_date & !control & treated ~ "B",
        # those who are vaccinated during the recruitment period but not on day 1
        vax1_type == brand & vax1_date <= study_dates$global$studyend_date & !control & !treated ~ "C",
        vax1_type == brand & vax1_date <= study_dates$global$studyend_date & !control & treated ~ "D",
        vax1_type == brand & vax1_date <= study_dates$global$studyend_date & control & !treated ~ "E",
        vax1_type == brand & vax1_date <= study_dates$global$studyend_date & control & treated ~ "F",
        # those who remain unvaccinated at the end of the recruitment period
        (is.na(vax1_date) | vax1_date > study_dates$global$studyend_date) & !control & !treated ~ "G",
        (is.na(vax1_date) | vax1_date > study_dates$global$studyend_date) & control & !treated ~ "H",
        # those who are vaccinated with the other brand
        vax1_date <= study_dates$global$studyend_date & control & !treated ~ "I",
        TRUE ~ NA_character_
      )
    )
  
  # count number in each category
  flowchart_matching <- data_match_flow %>% group_by(crit) %>% count() %>%
    right_join(flow_categories, by = "crit") %>%
    arrange(crit) %>% 
    mutate(across(n, ~if_else(is.na(.x), 0L, .x))) %>%
    mutate(brand = brand)
  
  # store patient_ids for those in category G, as there will be some overlap between pfizer and az
  GH_ids <- data_match_flow %>% filter(crit %in% c("G", "H")) %>% select(patient_id, crit)
  
  return(
    list(
      # data_match_flow = data_match_flow,
      flowchart_matching = flowchart_matching,
      GH_ids = GH_ids
    )
  )
  
}

flowchart_matching_pfizer <- flowchart_matching_function("pfizer")
flowchart_matching_az <- flowchart_matching_function("az")

# distinct patients meeting criteria H for *either* pfizer or az
n_H <- bind_rows(
  flowchart_matching_pfizer$GH_ids, 
  flowchart_matching_az$GH_ids
  ) %>% 
  filter(crit == "H") %>%
  distinct(patient_id) %>% 
  nrow()

# distinct patients meeting criteria G for *both* pfizer and az
n_G <- inner_join(
  flowchart_matching_pfizer$GH_ids, 
  flowchart_matching_az$GH_ids,
  by = c("patient_id", "crit")
  ) %>% 
  filter(crit == "G") %>%
  distinct(patient_id) %>% 
  nrow()


flowchart_matching_pfizer <- flowchart_matching_pfizer$flowchart_matching
flowchart_matching_az <- flowchart_matching_az$flowchart_matching

# single trial flowchart
flowchart_singleeligible_rounded <- readr::read_csv(here("output", "single", "eligible", "flowchart_singleeligible_any_rounded.csv"))
  
# brand-specific
flow_boxes_brand <- flow_boxes %>%
  # get rid of boxes with G as these have duplicates across the brands
  filter(!str_detect(box_crit, "G")) %>%
  # join to the counts for each criteria
  fuzzy_join(
    bind_rows(flowchart_matching_pfizer, flowchart_matching_az), 
    by = c("box_crit" = "crit"), 
    match_fun = str_detect,
    mode = "left"
  ) %>%
  # sum across all criteria in each box
  group_by(brand, box_crit, box_descr) %>%
  summarise(n = sum(n), .groups = "keep") 

# unvaccinated counts (not brand-specific)
flow_boxes_unvax <- flow_boxes %>%
  # get rid of boxes with G as these have duplicates across the brands
  filter(str_detect(box_crit, "G")) %>%
  fuzzy_join(
    flow_categories %>%
      filter(crit %in% c("G", "H")) %>%
      mutate(
        n = case_when(
          crit == "G" ~ n_G,
          crit == "H" ~ n_H
        )
      ), 
    by = c("box_crit" = "crit"), 
    match_fun = str_detect,
    mode = "left"
  ) %>%
  # sum across all criteria in each box
  group_by(box_crit, box_descr) %>%
  summarise(n = sum(n), .groups = "keep")  %>% 
  mutate(brand = "unvax")

# bind together and process final flowchart for report
flowchart_final <- bind_rows(
  flowchart_singleeligible_rounded %>% mutate(brand = "single"),
  bind_rows(
    flow_boxes_brand, 
    flow_boxes_unvax 
  ) %>%
    mutate(across(n, ~roundmid_any(n, to = threshold))) %>%
    rename(criteria = box_descr, crit = box_crit) 
) %>%
  rowwise() %>%
  mutate(across(criteria,~glue(.x)))
  
# save flowchart_final  
write_csv(
  flowchart_final,
  file.path(outdir, "flowchart_final_rounded.csv")
)
