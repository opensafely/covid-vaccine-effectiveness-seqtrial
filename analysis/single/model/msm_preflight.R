# # # # # # # # # # # # # # # # # # # # ## # # # # # # # # # # # # # # # # # # # 
# This script:
# imports processed data 
# checks that there are no separation issues between covariates and outcomes
#
# The script should be run via an action in the project.yaml
# The script must be accompanied by 3 arguments,
# 1. brand
# 2. the subgroup variable. Use "all" if no subgroups
# 3. outcome
# 4. ipw_sample_random_n
# 5. msm_sample_nonoutcomes_n
# # # # # # # # # # # # # # # # # # # # ## # # # # # # # # # # # # # # # # # # # 

# # # # # # # # # # # # # # # # # # # # ## # # # # # # # # # # # # # # # # # # # 
# Preliminaries ----

# import libraries 
library('tidyverse')
library('here')
library('glue')
library('gt')
library('gtsummary')

# import custom user functions and metadata
source(here("analysis", "design.R"))
source(here("analysis", "functions", "utility.R"))
source(here("analysis", "functions", "redaction.R"))
source(here("analysis", "functions", "survival.R"))
source(here("analysis", "single", "process", "process_data_days.R"))

# import command-line arguments
args <- commandArgs(trailingOnly=TRUE)
if(length(args)==0){
  removeobs <- FALSE
  brand <- "pfizer"
  subgroup <- "all"
  outcome <- "covidadmitted"
  # vax models use less follow up time because median time to vaccination (=outcome) is ~ 30 days
  ipw_sample_random_n <- 150000 
  # outcome models use more follow up time because longer to outcome, and much fewer outcomes than vaccinations
  msm_sample_nonoutcomes_n <- 50000 
} else {
  brand <- args[[1]]
  subgroup <- args[[2]]
  outcome <- args[[3]]
  ipw_sample_random_n <- as.integer(args[[4]])
  msm_sample_nonoutcomes_n <- as.integer(args[[5]])
  removeobs <- TRUE
}

# create output directory
outdir <- here("output", "single", brand, subgroup, outcome, "preflight")
fs::dir_create(outdir)

# save formulas to global environment
# defined in analysis/design.R
list2env(list_formula_single, globalenv())
formula_1 <- outcome ~ 1
# remove subgroup variable from covariate set
formula_remove_subgroup <- as.formula(paste0(". ~ . - ", subgroup))

# # # # # # # # # # # # # # # # # # # # ## # # # # # # # # # # # # # # # # # # # 
# define septab function  ----
# (checks that there are no separation issues between covariates and outcomes)

septab <- function(data, formula, subgroup_level, brand, outcome, name){
  
  tbltab <- data %>%
    select(all.vars(formula), all_of(subgroup_level)) %>%
    select(where(~(!is.double(.)))) %>%
    select(-age) %>%
    mutate(
      across(
        where(is.integer),
        ~as.character(.)
      )
    ) %>%
    split(.[[1]]) %>%
    map(~.[,-1] %>% select(all_of(subgroup_level), everything())) %>%
    map(
      function(data){
        map(data, redacted_summary_cat, redaction_threshold=0) %>%
          bind_rows(.id="variable") %>%
          select(-redacted, -pct_nonmiss)
      }
    )
  
  tbltab %>%
    bind_rows(.id = "event") %>%
    pivot_wider(
      id_cols=c(variable, .level),
      names_from = event,
      names_glue = "event{event}_{.value}",
      values_from = c(n, pct)
    ) %>%
    select(variable, .level, starts_with("event0"), starts_with("event1")) %>%
    gt(
      groupname_col="variable",
    ) %>%
    tab_spanner_delim("_") %>%
    fmt_number(
      columns = ends_with(c("pct")),
      decimals = 1,
      scale_by=100,
      pattern = "({x})"
    ) %>%
    gtsave(
      filename = glue("sepcheck_{subgroup_level}_{brand}_{outcome}_{name}.html"),
      outdir
    )
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Loop over all subgroup_levels ----

subgroup_levels <- recoder[[subgroup]]

for(subgroup_level in subgroup_levels){
      
      cat("  \n")
      cat(subgroup_level, "  \n")
      cat("  \n")
      
      # import processed data
      data_fixed <- read_rds(here("output", "single", "stset", "data_fixed.rds"))
      
      # read and process data_days (one row per person day)
      # see analysis/single/process/process_data_days.R for the process_data_days function
      data_days <- process_data_days(stage = "preflight")
      
      if(removeobs) rm(data_fixed)

      # define formulas      
      treatment_any <-
        update(vaxany1 ~ 1, formula_covars) %>% 
        update(formula_secular_region) %>% 
        update(formula_timedependent) %>% 
        update(formula_remove_subgroup)
      treatment_pfizer <-
        update(vaxpfizer1 ~ 1, formula_covars) %>% 
        update(formula_secular_region) %>% 
        update(formula_timedependent) %>%
        update(formula_remove_subgroup)
      treatment_az <-
        update(vaxaz1 ~ 1, formula_covars) %>%
        update(formula_secular_region) %>%
        update(formula_timedependent) %>% 
        update(formula_remove_subgroup)
      

      outcome_formula <- formula_1 %>% 
        update(formula_exposure) %>% 
        update(formula_covars) %>%
        update(formula_secular_region) %>%
        update(formula_timedependent) %>%
        update(formula_remove_subgroup)
      
      
      # vaccination models
      data_days_vax <- data_days %>%
        # select follow-up time where vax brand is being administered
        filter(vax_atrisk) 
      
      # generate data_samples_vax, summarise and save summary
      data_samples_vax <- data_days_vax %>%
        group_by(patient_id) %>%
        summarise(
          had_vax = any(vax>0),
        ) %>%
        ungroup() %>%
        transmute(
          patient_id,
          sample = sample_random_n(patient_id, ipw_sample_random_n)
        )
      
      data_days_vax_sample <- data_days_vax %>%
        left_join(data_samples_vax, by="patient_id") %>%
        filter(sample)
      
      data_days_vax_sample %>%
        summarise(
          obs = n(),
          patients = n_distinct(patient_id),
          vaxany1 = sum(vaxany1),
          vaxpfizer1 = sum(vaxpfizer1),
          vaxaz1 = sum(vaxaz1),
          rate_vaxany1 = vaxany1/patients,
          rate_vaxpfizer1 = vaxpfizer1/patients,
          rate_vaxaz1 = vaxaz1/patients,
          incidencerate_vaxany1 = vaxany1/obs,
          incidencerate_vaxpfizer1 = vaxpfizer1/obs,
          incidencerate_vaxaz1 = vaxaz1/obs
        ) %>%
        write_csv(
          file.path(outdir, glue("summary_{subgroup_level}_{brand}_{outcome}_vaccinations.csv"))
          )
      
      # apply septab function
      septab(data_days_vax_sample, treatment_any, subgroup_level, outcome, brand, "vaxany1")
      septab(data_days_vax_sample, treatment_pfizer, subgroup_level, outcome, brand, "vaxpfizer1")
      septab(data_days_vax_sample, treatment_az, subgroup_level, outcome, brand, "vaxaz1")
      
      if(removeobs) rm(data_samples_vax, data_days_vax, data_days_vax_sample)
      
      # outcome models
      data_samples_outcome <- data_days %>%
        group_by(patient_id) %>%
        summarise(
          had_outcome = any(outcome>0),
        ) %>%
        ungroup() %>%
        transmute(
          patient_id,
          sample = sample_nonoutcomes_n(had_outcome, patient_id, msm_sample_nonoutcomes_n),
          sample_weights = sample_weights(had_outcome, sample) # not used in this script
        )
      
      data_days_outcome_sample <- data_days %>%
        left_join(data_samples_outcome, by="patient_id") %>%
        filter(sample)
      
      data_days_outcome_sample %>%
        summarise(
          obs = n(),
          patients = n_distinct(patient_id),
          
          death = sum(death),
          dereg = sum(dereg),
          outcome = sum(outcome),
          
          rate_death = death/patients,
          rate_dereg = dereg/patients,
          rate_outcome = outcome/patients,
          
          incidencerate_death = death/obs,
          incidencerate_dereg = dereg/obs,
          incidencerate_outcome = outcome/obs
          
        ) %>%
        write_csv(
          file.path(outdir, glue("summary_{subgroup_level}_{brand}_{outcome}_outcomes.csv"))
        )
      
      septab(data_days_outcome_sample, outcome_formula, subgroup_level, outcome, brand, "outcome")
      
      if(removeobs) rm(data_samples_outcome, data_days, data_days_outcome_sample)
      
}
