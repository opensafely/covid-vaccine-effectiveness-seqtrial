
# # # # # # # # # # # # # # # # # # # # #
# This script:
# fits some marginal structural models for vaccine effectiveness, with different adjustment sets
# saves model summaries (tables and figures)
# "tte" = "time-to-event"
#
# The script should be run via an action in the project.yaml
# The script must be accompanied by 5 arguments:
# 1. the stratification variable. Use "all" if no stratification
# 2. the name of the outcome
# 3. the name of the brand (currently "any", "az",or "pfizer")
# 4. the sample size for the vaccination models (a completely random sample of participants)
# 5. the sample size for those who did not experience the outcome for the main MSM models (all those who did experience an outcome are included)
# # # # # # # # # # # # # # # # # # # # #

# Preliminaries ----

## Import libraries ----
library('tidyverse')
library('here')
library('glue')
library('survival')
library('splines')
library('parglm')
library('gtsummary')
library('gt')

## Import custom user functions from lib
source(here("lib", "utility_functions.R"))
source(here("lib", "redaction_functions.R"))
source(here("lib", "survival_functions.R"))

# import command-line arguments ----

args <- commandArgs(trailingOnly=TRUE)


if(length(args)==0){
  # use for interactive testing
  removeobs <- FALSE
  strata_var <- "all"
  brand <- "pfizer"
  outcome <- "covidadmitted"
  ipw_sample_random_n <- 20000 # vax models use less follow up time because median time to vaccination (=outcome) is ~ 30 days
  msm_sample_nonoutcomes_n <- 5000 # outcome models use more follow up time because longer to outcome, and much fewer outcomes than vaccinations
  
} else {
  removeobs <- TRUE
  cohort <- args[[1]]
  strata_var <- args[[2]]
  recentpostest_period <- as.numeric(args[[3]])
  brand <- args[[4]]
  outcome <- args[[5]]
  ipw_sample_random_n <- as.integer(args[[6]])
  msm_sample_nonoutcomes_n <- as.integer(args[[7]])
}


### define parglm optimisation parameters ----

parglmparams <- parglm.control(
  method = "LINPACK",
  nthreads = 8,
  maxit = 40 # default = 25
)



# reweight censored deaths or not?
# ideally yes, but often very few events so censoring models are not stable
reweight_death <- read_rds(here("output", "metadata", "reweight_death.rds")) == 1

## if changing treatment strategy as per Miguel's suggestion
exclude_recentpostest <- (recentpostest_period >0)

### import outcomes, exposures, and covariate formulae ----
## these are created in data_define_cohorts.R script

list_formula <- read_rds(here("output", "metadata", "list_formula.rds"))
list2env(list_formula, globalenv())

## if outcome is positive test, remove time-varying positive test info from covariate set
if(outcome=="postest" | exclude_recentpostest){
  formula_remove_postest <- as.formula(". ~ . - timesince_postesttdc_pw")
} else{
  formula_remove_postest <- as.formula(". ~ .")
}

formula_1 <- outcome ~ 1
formula_remove_strata_var <- as.formula(paste0(". ~ . - ", strata_var))


# create output directories ----
fs::dir_create(here("output", cohort, strata_var, recentpostest_period, brand, outcome))





# function to calculate weights for treatment model ----
## if exposure is any vaccine, then create model for vaccination by any brand + model for death for censoring weights
## if exposure is pfizer vaccine, then create model for vaccination by pfizer + model for az and model for death for censoring weights
## if exposure is az vaccine, then create model for vaccination by az + model for pfizer and model death for censoring weights
get_ipw_weights <- function(
  data,
  event,
  event_status,
  event_atrisk,
  
  sample_type,
  sample_amount,
  
  ipw_formula,
  ipw_formula_fxd,
  
  stratum
){
  
  stopifnot(sample_type %in% c("random_prop", "random_n", "nonoutcomes_n"))
  
  name <- str_remove(event_atrisk, "_atrisk")
  
  data_atrisk <- data %>%
    mutate(
      event = data[[event]],
      event_status = data[[event_status]],
      event_atrisk = data[[event_atrisk]],
    ) %>%
    filter(event_atrisk)
  
  if(sample_type=="nonoutcomes_prop"){
    data_sample <- data_atrisk %>%
      group_by(patient_id) %>%
      summarise(
        had_event = any(event>0)
      ) %>%
      ungroup() %>%
      transmute(
        patient_id,
        sample_event = sample_nonoutcomes_prop(had_event, patient_id, sample_amount),
        sample_weights_event = sample_weights(had_event, sample_event),
      )
  }
  
  if(sample_type=="nonoutcomes_n"){
    data_sample <- data_atrisk %>%
      group_by(patient_id) %>%
      summarise(
        had_event = any(event>0)
      ) %>%
      ungroup() %>%
      transmute(
        patient_id,
        sample_event = sample_nonoutcomes_n(had_event, patient_id, sample_amount),
        sample_weights_event = sample_weights(had_event, sample_event),
      )
  }
  
  if(sample_type=="random_prop"){
    data_sample <- data_atrisk %>%
      group_by(patient_id) %>%
      summarise() %>%
      ungroup() %>%
      transmute(
        patient_id,
        sample_event = sample_random_prop(patient_id, sample_amount),
        sample_weights_event = sample_event*1L,
      )
  }
  
  
  if(sample_type=="random_n"){
    data_sample <- data_atrisk %>%
      group_by(patient_id) %>%
      summarise() %>%
      ungroup() %>%
      transmute(
        patient_id,
        sample_event = sample_random_n(patient_id, sample_amount),
        sample_weights_event = sample_event*1L,
      )
  }
  
  data_atrisk_sample <- data_atrisk %>%
    left_join(data_sample, by="patient_id") %>%
    filter(sample_event)
  
  rm("data_sample")
  
  
  ### with time-updating covariates
  cat("  \n")
  cat(glue("{event}  \n"))
  
  event_model <- parglm(
    formula = ipw_formula,
    data = data_atrisk_sample,
    family = binomial,
    weights = sample_weights_event,
    control = parglmparams,
    na.action = "na.fail",
    model = FALSE
  )
  
  #apply jeffrey's prior to fitted model
  #library('brglm2')
  #event_model <- update(event_model, method = "brglmFit", type = "MPL_Jeffreys")
  
  #event_model$data <- NULL
  
  cat(glue("{event} data size = ", length(event_model$y)), "\n")
  cat(glue("memory usage = ", format(object.size(event_model), units="GB", standard="SI", digits=3L)), "\n")
  cat("warnings: ", "\n")
  print(warnings())
  
  ### without time-updating covariates ----
  
  cat("  \n")
  cat(glue("{event}_fxd  \n"))
  event_model_fxd <- parglm(
    formula = ipw_formula_fxd,
    data = data_atrisk_sample,
    family = binomial,
    weights = sample_weights_event,
    control = parglmparams,
    na.action = "na.fail",
    model = FALSE
  )
  
  #event_model_fxd$data <- NULL
  
  cat(glue("{event}_fxd data size = ", length(event_model_fxd$y)), "\n")
  cat(glue("memory usage = ", format(object.size(event_model_fxd), units="GB", standard="SI", digits=3L)), "\n")
  cat("warnings: ", "\n")
  print(warnings())
  
  #write_rds(data_atrisk, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("data_atrisk_{event}.rds")), compress="gz")
  write_rds(event_model, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("model_{name}_{stratum}.rds")), compress="gz")
  write_rds(ipw_formula, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("model_formula_{name}_{stratum}.rds")), compress="gz")
  
  rm("data_atrisk_sample")
  
  ## get predictions from model ----
  
  data_atrisk <- data_atrisk %>%
    transmute(
      patient_id,
      tstart, tstop,
      event,
      event_status,
      # get predicted probabilities from ipw models
      pred_event=predict(event_model, type="response", newdata=data_atrisk),
      pred_event_fxd=predict(event_model_fxd, type="response", newdata=data_atrisk)
    ) %>%
    arrange(patient_id, tstop) %>%
    group_by(patient_id) %>%
    mutate(
      
      # get probability of occurrence of realised event status (time varying model)
      probevent_realised = case_when(
        event!=1L ~ 1 - pred_event,
        event==1L ~ pred_event,
        TRUE ~ NA_real_
      ),
      # cumulative product of status probabilities
      #cmlprobevent_realised = cumprod(probevent_realised),
      # inverse probability weights
      #cmlipweight = 1/cmlprobevent_realised,
      
      
      # get probability of occurrence of realised event status (non-time varying model)
      probevent_realised_fxd = case_when(
        event!=1L ~ 1 - pred_event_fxd,
        event==1L ~ pred_event_fxd,
        TRUE ~ NA_real_
      ),
      # cumulative product of status probabilities
      #cmlprobevent_realised_fxd = cumprod(probevent_realised_fxd),
      # inverse probability weights
      #cmlipweight_fxd = 1/cmlprobevent_realised_fxd,
      
      # stabilised inverse probability weights
      ipweight_stbl = probevent_realised_fxd/probevent_realised,
      
      # stabilised inverse probability weights (cumulative)
      #cmlipweight_stbl = cmlprobevent_realised_fxd/cmlprobevent_realised,
    ) %>%
    ungroup()
  
  
  stopifnot("probs should all be non-null" = all(!is.na(data_atrisk$probevent_realised)))
  stopifnot("probs (fxd) should all be non-null" = all(!is.na(data_atrisk$probevent_realised_fxd)))
  
  weights <- data_atrisk %>%
    select(
      patient_id,
      tstart, tstop,
      ipweight_stbl
    )
  
  weights[[glue("ipweight_stbl_{name}")]] <- weights$ipweight_stbl
  weights$ipweight_stbl <- NULL
  
  return(weights)
}



##  Create big loop over all strata

strata <- read_rds(here("output", "metadata", "list_strata.rds"))[[strata_var]]

for(stratum in strata){
  
  cat("  \n")
  cat(stratum, "  \n")
  cat("  \n")
  
  # Import processed data ----
  data_fixed <- read_rds(here("output", cohort, "data", glue("data_fixed.rds")))
  
  data_samples <- read_rds(here("output", cohort, "data", "data_tte.rds")) %>%
    left_join(data_fixed, by="patient_id") %>%
    mutate(
      all = factor("all",levels=c("all")),
      tte_outcome = .[[glue("tte_{outcome}")]]
    ) %>%
    filter(
      .[[strata_var]] == stratum # select patients in current stratum
    ) %>%
    transmute(
      patient_id,
      sample_outcome = sample_nonoutcomes_n(!is.na(tte_outcome), patient_id, msm_sample_nonoutcomes_n),
      sample_weights = sample_weights(!is.na(tte_outcome), sample_outcome),
    )
  
  
  ## read and process person-time dataset -- do this _within_ loop so that it can be deleted just before models are run, to reduce RAM use
  data_pt_sub <- read_rds(here("output", cohort, "data", glue("data_pt.rds"))) %>% # person-time dataset (one row per patient per day)
    left_join(data_samples, by="patient_id") %>%
    mutate(all = factor("all",levels=c("all"))) %>%
    filter(
      .[[glue("{outcome}_status")]] == 0, # follow up ends at (day after) occurrence of outcome, ie where status not >0
      lastfup_status == 0, # follow up ends at (day after) occurrence of censoring event (derived from lastfup = min(end_date, death, dereg))
      vaxany1_status == .[[glue("vax{brand}1_status")]], # if brand-specific, follow up ends at (day after) occurrence of competing vaccination, ie where vax{competingbrand}_status not >0
      vaxany2_status == 0, # censor at second dose
      .[[glue("vax{brand}_atrisk")]] == 1, # select follow-up time where vax brand is being administered
    ) %>%
    left_join(data_fixed, by="patient_id") %>%
    filter(
      .[[strata_var]] == stratum # select patients in current stratum
    ) %>%
    mutate(
      timesincevax_pw = timesince_cut(vaxany1_timesince, postvaxcuts, "pre-vax"),
      outcome = .[[outcome]],
    ) %>%
    mutate( # this step converts logical to integer so that model coefficients print nicely in gtsummary methods
      across(where(is.logical), ~.x*1L)
    ) %>%
    mutate(
      recentpostest = (replace_na(between(postest_timesince, 1, recentpostest_period), FALSE) & exclude_recentpostest),
      vaxany1_atrisk = (vaxany1_status==0 & lastfup_status==0 & vaxany_atrisk==1 & (!recentpostest)),
      vaxpfizer1_atrisk = (vaxany1_status==0 & lastfup_status==0 & vaxpfizer_atrisk==1 & (!recentpostest)),
      vaxaz1_atrisk = (vaxany1_status==0 & lastfup_status==0 & vaxaz_atrisk==1 & (!recentpostest)),
      death_atrisk = (death_status==0 & lastfup_status==0),
    ) %>%
    mutate(
      vax_atrisk = .[[glue("vax{brand}1_atrisk")]]
    ) %>%
    select(
      "patient_id",
      "all",
      "tstart", "tstart",
      "outcome",
      "timesincevax_pw",
      any_of(all.vars(formula_all_rhsvars)),
      "sample_weights", "sample_outcome",
      "recentpostest",
      "vaxany1_atrisk",
      "vaxpfizer1_atrisk",
      "vaxaz1_atrisk",
      "death_atrisk",
      "vax_atrisk",
      "vaxany1",
      "vaxpfizer1",
      "vaxaz1",
      "vaxany1_status",
      "vaxpfizer1_status",
      "vaxaz1_status",
    )
  
  if(removeobs) rm(data_samples, data_fixed)
  
  
  ### print dataset size ----
  cat(glue("data_pt_sub data size = ", nrow(data_pt_sub)), "\n  ")
  cat(glue("data_pt_sub patient size = ", n_distinct(data_pt_sub$patient_id)), "\n  ")
  cat(glue("memory usage = ", format(object.size(data_pt_sub), units="GB", standard="SI", digits=3L)), "\n  ")
  
  
  
  if(brand=="any"){
    
    # IPW model for any vaccination ----
    weights_vaxany1 <- get_ipw_weights(
      data_pt_sub, "vaxany1", "vaxany1_status", "vaxany1_atrisk",
      sample_type="random_n", sample_amount=ipw_sample_random_n,
      ipw_formula =     update(vaxany1 ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_timedependent) %>% update(formula_remove_postest) %>% update(formula_remove_strata_var),
      ipw_formula_fxd = update(vaxany1 ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
      stratum = stratum
    )
  }
  if(brand!="any"){
    
    # IPW model for pfizer / az vaccination ----
    # these models are shared across brands (one is treatment model, one is censoring model)
    # these could be separated out and run only once, but it complicates the remaining workflow so leaving as is
    weights_vaxpfizer1 <- get_ipw_weights(
      data_pt_sub, "vaxpfizer1", "vaxpfizer1_status", "vaxpfizer1_atrisk",
      sample_type="random_n", sample_amount=ipw_sample_random_n, # select no more than n non-outcome samples
      ipw_formula =     update(vaxpfizer1 ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_timedependent) %>% update(formula_remove_postest) %>% update(formula_remove_strata_var),
      ipw_formula_fxd = update(vaxpfizer1 ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
      stratum = stratum
    )
    weights_vaxaz1 <- get_ipw_weights(
      data_pt_sub, "vaxaz1", "vaxaz1_status", "vaxaz1_atrisk",
      sample_type="random_n", sample_amount=ipw_sample_random_n,
      ipw_formula =     update(vaxaz1 ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_timedependent) %>% update(formula_remove_postest) %>% update(formula_remove_strata_var),
      ipw_formula_fxd = update(vaxaz1 ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
      stratum = stratum
    )
  }
  
  # IPW model for death ----
  
  ## if outcome is not death, then need to account for censoring by any cause death
  if(!(outcome %in% c("death", "coviddeath", "noncoviddeath")) & reweight_death){
    weights_death <- get_ipw_weights(
      data_pt_sub, "death", "death_status", "death_atrisk",
      sample_type="nonoutcomes_n", sample_amount=ipw_sample_random_n,
      ipw_formula =     update(death ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_exposure) %>% update(formula_secular_region) %>% update(formula_timedependent) %>% update(formula_remove_postest) %>% update(formula_remove_strata_var),
      ipw_formula_fxd = update(death ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_exposure) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
      stratum = stratum
    )
  }
  ## if outcome is covid death, then need to account for censoring by non-covid deaths
  if(outcome=="coviddeath" & reweight_death){
    weights_death <- get_ipw_weights(
      data_pt_sub, "noncoviddeath", "noncoviddeath_status", "death_atrisk",
      sample_type="nonoutcomes_n", sample_amount=msm_sample_nonoutcomes_n,
      ipw_formula =     update(noncoviddeath ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_exposure) %>% update(formula_secular_region) %>% update(formula_timedependent) %>% update(formula_remove_postest) %>% update(formula_remove_strata_var),
      ipw_formula_fxd = update(noncoviddeath ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_exposure) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
      stratum = stratum
    )
  }
  ## if outcome is noncovid death, then need to account for censoring by covid deaths
  if(outcome=="noncoviddeath" & reweight_death){
    weights_death <- get_ipw_weights(
      data_pt_sub, "coviddeath", "coviddeath_status", "death_atrisk",
      sample_type="nonoutcomes_n", sample_amount=msm_sample_nonoutcomes_n,
      ipw_formula =     update(coviddeath ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_exposure) %>% update(formula_secular_region) %>% update(formula_timedependent) %>% update(formula_remove_postest) %>% update(formula_remove_strata_var),
      ipw_formula_fxd = update(coviddeath ~ 1, formula_demog) %>% update(formula_comorbs) %>% update(formula_exposure) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
      stratum = stratum
    )
  }
  ## if outcome is death, then no accounting for censoring by death is needed
  if(outcome=="death" | !reweight_death){
    weights_death <- data_pt_sub %>%
      filter(death_atrisk) %>%
      transmute(
        patient_id, tstart, tstop,
        ipweight_stbl_death=1,
        cmlipweight_stbl_death=1,
      )
  }
  
  if(brand=="any"){
    data_weights <- data_pt_sub %>%
      filter(
        sample_outcome==1L # select all patients who experienced the outcome, and a proportion (determined in data_sample action) of those who don't
      ) %>%
      left_join(weights_vaxany1, by=c("patient_id", "tstart", "tstop")) %>%
      left_join(weights_death, by=c("patient_id", "tstart", "tstop")) %>%
      replace_na(list(
        # weight is 1 if patient is not yet at risk or has already been vaccinated / censored
        ipweight_stbl_vaxany1 = 1,
        ipweight_stbl_death = 1
      )) %>%
      arrange(patient_id, tstop) %>%
      group_by(patient_id) %>%
      mutate(
        cmlipweight_stbl_vaxany1 = cumprod(ipweight_stbl_vaxany1),
        cmlipweight_stbl_death = cumprod(ipweight_stbl_death),
      ) %>%
      ungroup() %>%
      mutate(
        ipweight_stbl = ipweight_stbl_vaxany1 * ipweight_stbl_death,
        ipweight_stbl_sample = ipweight_stbl * sample_weights,
        cmlipweight_stbl = cmlipweight_stbl_vaxany1 * cmlipweight_stbl_death,
        cmlipweight_stbl_sample = cmlipweight_stbl * sample_weights,
      )
    
    if(removeobs) rm(weights_vaxany1, weights_death)
  }
  if(brand != "any"){
    
    data_weights <- data_pt_sub %>%
      filter(
        sample_outcome==1L # select all patients who experienced the outcome, and a proportion (determined in data_sample action) of those who don't
      ) %>%
      left_join(weights_vaxpfizer1, by=c("patient_id", "tstart", "tstop")) %>%
      left_join(weights_vaxaz1, by=c("patient_id", "tstart", "tstop")) %>%
      left_join(weights_death, by=c("patient_id", "tstart", "tstop")) %>%
      replace_na(list( # weight is 1 if patient is not yet at risk or has already been vaccinated / censored
        ipweight_stbl_vaxpfizer1 = 1,
        ipweight_stbl_vaxaz1 = 1,
        ipweight_stbl_death = 1
      )) %>%
      arrange(patient_id, tstop) %>%
      group_by(patient_id) %>%
      mutate(
        cmlipweight_stbl_vaxpfizer1 = cumprod(ipweight_stbl_vaxpfizer1),
        cmlipweight_stbl_vaxaz1 = cumprod(ipweight_stbl_vaxaz1),
        cmlipweight_stbl_death = cumprod(ipweight_stbl_death),
      ) %>%
      ungroup() %>%
      mutate(
        ## COMBINE WEIGHTS
        # take product of all weights
        ipweight_stbl = ipweight_stbl_vaxpfizer1 * ipweight_stbl_vaxaz1 * ipweight_stbl_death,
        ipweight_stbl_sample = ipweight_stbl * sample_weights,
        
        cmlipweight_stbl = cmlipweight_stbl_vaxpfizer1 * cmlipweight_stbl_vaxaz1 * cmlipweight_stbl_death,
        cmlipweight_stbl_sample = cmlipweight_stbl * sample_weights,
      )
    if(removeobs) rm(weights_vaxpfizer1, weights_vaxaz1, weights_death)
  }
  
  
  if(removeobs) rm(data_pt_sub)
  
  ## report weights ----
  summarise_weights <-
    data_weights %>%
    select(contains("ipweight")) %>%
    map(redacted_summary_num) %>%
    enframe()
  
  capture.output(
    walk2(summarise_weights$value, summarise_weights$name, print_num),
    file = here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("weights_table_{stratum}.txt")),
    append=FALSE
  )
  
  ## save weights
  weight_histogram <- data_weights %>%
    filter(vax_atrisk==1) %>%
    ggplot() +
    geom_histogram(aes(x=ipweight_stbl)) +
    scale_x_log10()+
    theme_bw()
  
  ggsave(here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("weights_prob_histogram_{stratum}.svg")), weight_histogram)
  
  
  weight_histogram <- data_weights %>%
    ggplot() +
    geom_histogram(aes(x=cmlipweight_stbl)) +
    scale_x_log10()+
    theme_bw()
  
  ggsave(here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("weights_cmlprob_histogram_{stratum}.svg")), weight_histogram)
  if(removeobs) rm(weight_histogram)
  
  ## output weight distribution file ----
  data_weights <- data_weights %>%
    mutate(
      # recode treatment variable to remove vaccines occurring after a positive test
      timesincevax_pw = if_else(!recentpostest, timesincevax_pw, factor("pre-vax"))
    ) %>%
    select(
      "patient_id",
      "tstart", "tstop",
      any_of(all.vars(formula_all_rhsvars)),
      "sample_weights",
      "ipweight_stbl",
      "ipweight_stbl_sample",
      "cmlipweight_stbl",
      "cmlipweight_stbl_sample",
      "outcome",
    )
  
  cat("  \n")
  cat(glue("data_weights data size = ", nrow(data_weights)), "  \n")
  cat(glue("memory usage = ", format(object.size(data_weights), units="GB", standard="SI", digits=3L)), "  \n")
  
  write_rds(data_weights, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("data_weights_{stratum}.rds")), compress="gz")
  
  
  # MSM model ----
  
  # do not use time-dependent covariates as these are accounted for with the weights
  # use cluster standard errors
  # use quasibinomial to suppress "non-integer #successes in a binomial glm!" warning (not possible with parglm)
  # use interaction with time terms?
  
  ### model 0 - unadjusted vaccination effect model ----
  ## no adjustment variables
  # cat("  \n")
  # cat("msmmod0 \n")
  # msmmod0_par <- parglm(
  #   formula = formula_1 %>% update(formula_exposure) %>% update(formula_remove_strata_var),
  #   data = data_weights,
  #   family = binomial,
  #   weights = sample_weights,
  #   control = parglmparams,
  #   na.action = "na.fail",
  #   model = FALSE
  # )
  #
  # msmmod0_par$data <- NULL
  # print(jtools::summ(msmmod0_par, digits =3))
  #
  # cat(glue("msmmod0_par data size = ", length(msmmod0_par$y)), "\n")
  # cat(glue("memory usage = ", format(object.size(msmmod0_par), units="GB", standard="SI", digits=3L)), "\n")
  # write_rds(msmmod0_par, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("model0_{stratum}.rds")), compress="gz")
  # if(removeobs) rm(msmmod0_par)
  
  ### model 1 - adjusted vaccination effect model and region/time only ----
  cat("  \n")
  cat("msmmod1 \n")
  msmmod1_par <- parglm(
    formula = formula_1 %>% update(formula_exposure) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
    data = data_weights,
    family = binomial,
    weights = sample_weights,
    control = parglmparams,
    na.action = "na.fail",
    model = FALSE
  )
  
  msmmod1_par$data <- NULL
  print(jtools::summ(msmmod1_par, digits =3))
  cat("warnings: ", "\n")
  print(warnings())
  
  cat(glue("msmmod1_par data size = ", length(msmmod1_par$y)), "\n")
  cat(glue("memory usage = ", format(object.size(msmmod1_par), units="GB", standard="SI", digits=3L)), "\n")
  write_rds(msmmod1_par, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("model1_{stratum}.rds")), compress="gz")
  if(removeobs) rm(msmmod1_par)
  
  
  
  ### model 2 - baseline, comorbs, secular trend adjusted vaccination effect model ----
  cat("  \n")
  cat("msmmod2 \n")
  msmmod2_par <- parglm(
    formula = formula_1 %>% update(formula_exposure) %>% update(formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
    data = data_weights,
    family = binomial,
    weights = sample_weights,
    control = parglmparams,
    na.action = "na.fail",
    model = FALSE
  )
  msmmod2_par$data <- NULL
  print(jtools::summ(msmmod2_par, digits =3))
  cat("warnings: ", "\n")
  print(warnings())
  
  cat(glue("msmmod2_par data size = ", length(msmmod2_par$y)), "\n")
  cat(glue("memory usage = ", format(object.size(msmmod2_par), units="GB", standard="SI", digits=3L)), "\n")
  write_rds(msmmod2_par, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("model2_{stratum}.rds")), compress="gz")
  
  if(removeobs) rm(msmmod2_par)
  
  
  ### model 3 - baseline, comorbs, secular trends and time-varying (but not reweighted) adjusted vaccination effect model ----
  cat("  \n")
  cat("msmmod3 \n")
  msmmod3_par <- parglm(
    formula = formula_1 %>% update(formula_exposure) %>% update(formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_timedependent) %>% update(formula_remove_postest) %>% update(formula_remove_strata_var),
    data = data_weights,
    family = binomial,
    weights = sample_weights,
    control = parglmparams,
    na.action = "na.fail",
    model = FALSE
  )
  msmmod3_par$data <- NULL
  print(jtools::summ(msmmod3_par, digits =3))
  cat("warnings: ", "\n")
  print(warnings())
  
  cat(glue("msmmod3_par data size = ", length(msmmod3_par$y)), "\n")
  cat(glue("memory usage = ", format(object.size(msmmod3_par), units="GB", standard="SI", digits=3L)), "\n")
  write_rds(msmmod3_par, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("model3_{stratum}.rds")), compress="gz")
  if(removeobs) rm(msmmod3_par)
  
  
  
  ### model 4 - baseline, comorbs, secular trend adjusted vaccination effect model + IP-weighted + do not use time-dependent covariates ----
  cat("  \n")
  cat("msmmod4 \n")
  msmmod4_par <- parglm(
    formula = formula_1 %>% update(formula_exposure)  %>% update(formula_demog) %>% update(formula_comorbs) %>% update(formula_secular_region) %>% update(formula_remove_strata_var),
    data = data_weights,
    weights = cmlipweight_stbl_sample,
    family = binomial,
    control = parglmparams,
    na.action = "na.fail",
    model = FALSE
  )
  msmmod4_par$data <- NULL
  print(jtools::summ(msmmod4_par, digits =3))
  cat("warnings: ", "\n")
  print(warnings())
  
  cat(glue("msmmod4_par data size = ", length(msmmod4_par$y)), "\n")
  cat(glue("memory usage = ", format(object.size(msmmod4_par), units="GB", standard="SI", digits=3L)), "\n")
  write_rds(msmmod4_par, here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("model4_{stratum}.rds")), compress="gz")
  if(removeobs) rm(msmmod4_par)
  
  
  ## print warnings
  cat("warnings: ", "\n")
  print(warnings())
  cat("  \n")
  print(gc(reset=TRUE))
  
  
  data_weights %>%
    summarise(
      obs = n(),
      patients = n_distinct(patient_id),
      outcomes = sum(outcome),
      incidence_prop = outcomes/patients,
      incidence_rate = outcomes/obs
    ) %>%
    write_csv(path=here("output", cohort, strata_var, recentpostest_period, brand, outcome, glue("summary_substantive_{stratum}.csv")))
  
  
  if(removeobs) rm(data_weights)
}
