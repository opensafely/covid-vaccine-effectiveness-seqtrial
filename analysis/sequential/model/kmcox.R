# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# This script: 
#  - imports matched data
#  - adds outcome variable and restricts follow-up
#  - gets KM estimates
#  - gets Cox HR estimates
#  - The script must be accompanied by three arguments:
#    `brand` - pfizer or az
#    `subgroup` - prior_covid_infection
#    `outcome` - the dependent variable
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

# Preliminaries ----

# import libraries
library('tidyverse')
library('here')
library('glue')
library('survival')

# import local functions and parameters
source(here("analysis", "design.R"))
source(here("analysis", "functions", "utility.R"))
source(here("analysis", "functions", "survival.R"))

# import command-line arguments
args <- commandArgs(trailingOnly=TRUE)
if(length(args)==0){
  # use for interactive testing
  brand <- "pfizer"
  subgroup <- "all"
  outcome <- "postest"
} else {
  brand <- args[[1]]
  subgroup <- args[[2]]
  outcome <- args[[3]]
}

# derive symbolic arguments for programming with
brand_sym <- sym(brand)
subgroup_sym <- sym(subgroup)

# create output directories
outdir <- ghere("output", "sequential", brand, "model", subgroup, outcome)
fs::dir_create(outdir)

# read matched data
data_matched <- read_rds(ghere("output", "sequential", brand, "match", "data_matched.rds"))

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# process data ----
# import baseline data, restrict to matched individuals and derive time-to-event variables
data_matched <- 
  data_matched %>%
  mutate(all="all") %>%
  group_by(patient_id, match_id, matching_round, treated) %>% 
  mutate(new_id = cur_group_id()) %>% 
  ungroup() %>%
  select(
    # select only variables needed for models to save space
    patient_id, treated, trial_date, match_id, new_id,
    controlistreated_date,
    vax1_date,
    death_date, dereg_date, vax2_date,
    all_of(c(glue("{outcome}_date"), subgroup, adjustment_variables_sequential))
  ) %>%
  mutate(

    outcome_date = .data[[glue("{outcome}_date")]],
    
    # follow-up time is up to and including censor date
    censor_date = pmin(
      dereg_date,
      vax2_date - 1, # -1 because we assume vax occurs at the start of the day
      death_date,
      study_dates[["global"]]$studyend_date,
      trial_date - 1 + maxfup,
      na.rm=TRUE
    ),
    
    matchcensor_date = pmin(censor_date, controlistreated_date -1, na.rm=TRUE), # new censor date based on whether control gets treated or not

    tte_outcome = tte(trial_date - 1, outcome_date, matchcensor_date, na.censor=FALSE), # -1 because we assume vax occurs at the start of the day, and so outcomes occurring on the same day as treatment are assumed "1 day" long
    ind_outcome = censor_indicator(outcome_date, matchcensor_date),
    
  )

# outcome frequency
outcomes_per_treated <- table(outcome=data_matched$ind_outcome, treated=data_matched$treated)

table(
  data_matched$treated,
  cut(data_matched$tte_outcome, c(-Inf, 0, 1, Inf), right=FALSE, labels= c("<0", "0", ">0")), 
  useNA="ifany"
)
# should be c(0, 0, nrow(data_matched)) in each row

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# calculate KM estimates  ----
data_surv <-
  data_matched %>%
  group_by(treated, !!subgroup_sym) %>%
  nest() %>%
  mutate(
    surv_obj = map(data, ~{
      survfit(Surv(tte_outcome, ind_outcome) ~ 1, data = .x)
    }),
    surv_obj_tidy = map(surv_obj, ~{
      broom::tidy(.x) %>%
      complete(
        time = seq_len(maxfup), # fill in 1 row for each day of follow up
        fill = list(n.event = 0, n.censor = 0) # fill in zero events on those days
      ) %>%
      fill(n.risk, .direction = c("up")) # fill in n.risk on each zero-event day
    }), # return survival table for each day of follow up
  ) %>%
  select(!!subgroup_sym, treated, surv_obj_tidy) %>%
  unnest(surv_obj_tidy)

km_process <- function(.data, round_by) {
  
  .data %>% 
    mutate(
      
      lagtime = lag(time, 1, 0),
      leadtime = lead(time, 1, max(time)+1),
      interval = time - lagtime,
      
      N = max(n.risk, na.rm=TRUE),
      
      # rounded to `round_by - (round_by/2)`
      cml.eventcensor = roundmid_any(cumsum(n.event+n.censor), round_by),
      cml.event = roundmid_any(cumsum(n.event), round_by),
      cml.censor = cml.eventcensor - cml.event,
      
      n.event = diff(c(0, cml.event)),
      n.censor = diff(c(0, cml.censor)),
      n.risk = roundmid_any(N, round_by) - lag(cml.eventcensor, 1, 0),
      
      # KM estimate for event of interest, combining censored and competing events as censored
      summand = (1/(n.risk-n.event)) - (1/n.risk), # = n.event / ((n.risk - n.event) * n.risk) but re-written to prevent integer overflow
      surv = cumprod(1 - n.event / n.risk),
      surv.se = surv * sqrt(cumsum(summand)), #greenwood's formula
      surv.ln.se = surv.se/surv,
      
      ## standard errors on log scale
      #surv.ll = exp(log(surv) + qnorm(0.025)*surv.ln.se),
      #surv.ul = exp(log(surv) + qnorm(0.975)*surv.ln.se),
      
      llsurv = log(-log(surv)),
      llsurv.se = sqrt((1 / log(surv)^2) * cumsum(summand)),
      
      ## standard errors on complementary log-log scale
      surv.ll = exp(-exp(llsurv + qnorm(0.975)*llsurv.se)),
      surv.ul = exp(-exp(llsurv + qnorm(0.025)*llsurv.se)),
      
      risk = 1 - surv,
      risk.se = surv.se,
      risk.ln.se = surv.ln.se,
      risk.ll = 1 - surv.ul,
      risk.ul = 1 - surv.ll
      
    ) %>% 
    select(
      
      !!subgroup_sym, treated, time, lagtime, leadtime, interval,
      cml.event, cml.censor,
      n.risk, n.event, n.censor,
      surv, surv.se, surv.ll, surv.ul,
      risk, risk.se, risk.ll, risk.ul
      
    )  
  
}
 
data_surv_unrounded <- km_process(data_surv, 1)
data_surv_rounded <- km_process(data_surv, threshold)

write_rds(data_surv_unrounded, fs::path(outdir, "km_estimates_unrounded.rds"), compress = "gz")
write_rds(data_surv_rounded, fs::path(outdir, "km_estimates_rounded.rds"), compress = "gz")

km_plot <- function(.data) {
  .data %>%
    group_modify(
      ~add_row(
        .x,
        time=0,
        lagtime=0,
        leadtime=1,
        #interval=1,
        surv=1,
        surv.ll=1,
        surv.ul=1,
        risk=0,
        risk.ll=0,
        risk.ul=0,
        .before=0
      )
    ) %>%
    mutate(
      treated_descr = fct_recoderelevel(treated, recoder$treated),
    ) %>%
    ggplot(aes(group=treated_descr, colour=treated_descr, fill=treated_descr)) +
    geom_step(aes(x=time, y=risk), direction="vh")+
    geom_step(aes(x=time, y=risk), direction="vh", linetype="dashed", alpha=0.5)+
    geom_rect(aes(xmin=lagtime, xmax=time, ymin=risk.ll, ymax=risk.ul), alpha=0.1, colour="transparent")+
    facet_grid(rows=vars(!!subgroup_sym))+
    scale_color_brewer(type="qual", palette="Set1", na.value="grey") +
    scale_fill_brewer(type="qual", palette="Set1", guide="none", na.value="grey") +
    scale_x_continuous(breaks = seq(0,600,14))+
    scale_y_continuous(expand = expansion(mult=c(0,0.01)))+
    coord_cartesian(xlim=c(0, NA))+
    labs(
      x="Days",
      y="Cumulative incidence",
      colour=NULL,
      title=NULL
    )+
    theme_minimal()+
    theme(
      axis.line.x = element_line(colour = "black"),
      panel.grid.minor.x = element_blank(),
      legend.position=c(.05,.95),
      legend.justification = c(0,1),
    )
}

km_plot_unrounded <- km_plot(data_surv_unrounded)
km_plot_rounded <- km_plot(data_surv_rounded)

ggsave(filename=fs::path(outdir, "km_plot_unrounded.png"), km_plot_unrounded, width=20, height=15, units="cm")
ggsave(filename=fs::path(outdir, "km_plot_rounded.png"), km_plot_rounded, width=20, height=15, units="cm")

# calculate quantities relating to cumulative incidence curve and their ratio / difference / etc
kmcontrasts <- function(data, cuts=NULL){
  
  # if cuts=NULL then function provides daily estimates
  # if eg c(0,14,28,42,...) then follow u[ is split on these days
  # c(0, 140)
  
  if(is.null(cuts)){cuts <- unique(c(0,data$time))}
  
  data %>%
    filter(time!=0) %>%
    transmute(
      !!subgroup_sym,
      treated,
      
      time, lagtime, interval,
      period_start = as.integer(as.character(cut(time, cuts, right=TRUE, label=cuts[-length(cuts)]))),
      period_end = as.integer(as.character(cut(time, cuts, right=TRUE, label=cuts[-1]))),
      period = cut(time, cuts, right=TRUE, label=paste0(cuts[-length(cuts)]+1, " - ", cuts[-1])),
      
      n.atrisk = n.risk,
      n.event, n.censor,
      
      cml.persontime = cumsum(n.atrisk*interval),
      cml.event = cumsum(replace_na(n.event, 0)),
      cml.censor = cumsum(replace_na(n.censor, 0)),
      
      rate = n.event / n.atrisk,
      cml.rate = cml.event / cml.persontime,
      
      surv, surv.se, surv.ll, surv.ul,
      risk, risk.se, risk.ll, risk.ul,
      
      inc = -(surv-lag(surv,1,1))/lag(surv,1,1),
      
      inc2 = diff(c(0,-log(surv)))
      
    ) %>%
    group_by(!!subgroup_sym, treated, period_start, period_end, period) %>%
    summarise(
      
      ## time-period-specific quantities
      
      persontime = sum(n.atrisk*interval), # total person-time at risk within time period
      
      inc = weighted.mean(inc, n.atrisk*interval),
      inc2 = weighted.mean(inc2, n.atrisk*interval),
      
      n.atrisk = first(n.atrisk), # number at risk at start of time period
      n.event = sum(n.event, na.rm=TRUE), # number of events within time period
      n.censor = sum(n.censor, na.rm=TRUE), # number censored within time period
      
      inc = n.event/persontime, # = weighted.mean(kmhaz, n.atrisk*interval), incidence rate. this is equivalent to a weighted average of the hazard ratio, with time-exposed as the weights
      
      interval = sum(interval[n.atrisk>0]), # width of time period
      
      ## quantities calculated from time zero until end of time period
      # these should be the same as the daily values as at the end of the time period
      
      surv = last(surv[n.atrisk>0]),
      surv.se = last(surv.se[n.atrisk>0]),
      surv.ll = last(surv.ll[n.atrisk>0]),
      surv.ul = last(surv.ul[n.atrisk>0]),
      
      risk = last(risk[n.atrisk>0]),
      risk.se = last(risk.se[n.atrisk>0]),
      risk.ll = last(risk.ll[n.atrisk>0]),
      risk.ul = last(risk.ul[n.atrisk>0]),
      
      cml.rate = last(cml.rate[n.atrisk>0]), # event rate from time zero to end of time period
      
      cml.event = last(cml.event[n.atrisk>0]), # number of events from time zero to end of time period
      
      .groups="drop"
    ) %>%
    ungroup() %>%
    pivot_wider(
      id_cols= all_of(c(subgroup, "period_start", "period_end", "period")),
      names_from=treated,
      names_glue="{.value}_{treated}",
      values_from=c(
        interval,
        persontime, n.atrisk, n.event, n.censor,
        inc, inc2,
        surv, surv.se, surv.ll, surv.ul,
        risk, risk.se, risk.ll, risk.ul,
        cml.event, cml.rate
      )
    ) %>%
    mutate(
      n.nonevent_0 = n.atrisk_0 - n.event_0,
      n.nonevent_1 = n.atrisk_1 - n.event_1,
      
      ## time-period-specific quantities
      
      # incidence rate ratio
      irr = inc_1 / inc_0,
      irr.ln.se = sqrt((1/n.event_0) + (1/n.event_1)),
      irr.ll = exp(log(irr) + qnorm(0.025)*irr.ln.se),
      irr.ul = exp(log(irr) + qnorm(0.975)*irr.ln.se),
      
      
      # incidence rate ratio, v2
      irr2 = inc2_1 / inc2_0,
      irr2.ln.se = sqrt((1/n.event_0) + (1/n.event_1)),
      irr2.ll = exp(log(irr2) + qnorm(0.025)*irr2.ln.se),
      irr2.ul = exp(log(irr2) + qnorm(0.975)*irr2.ln.se),
      
      # incidence rate difference
      #ird = rate_1 - rate_0,
      
      ## quantities calculated from time zero until end of time period
      # these should be the same as values calculated on each day of follow up
      
      # cumulative incidence rate ratio
      cmlirr = cml.rate_1 / cml.rate_0,
      cmlirr.ln.se = sqrt((1/cml.event_0) + (1/cml.event_1)),
      cmlirr.ll = exp(log(cmlirr) + qnorm(0.025)*cmlirr.ln.se),
      cmlirr.ul = exp(log(cmlirr) + qnorm(0.975)*cmlirr.ln.se),
      
      # survival ratio, standard error, and confidence limits
      sr = surv_1 / surv_0,
      #cisr.ln = log(cisr),
      sr.ln.se = (surv.se_0/surv_0) + (surv.se_1/surv_1), #because cmlhaz = -log(surv) and cmlhaz.se = surv.se/surv
      sr.ll = exp(log(sr) + qnorm(0.025)*sr.ln.se),
      sr.ul = exp(log(sr) + qnorm(0.975)*sr.ln.se),
      
      # risk ratio, standard error, and confidence limits, using delta method
      rr = risk_1 / risk_0,
      #cirr.ln = log(cirr),
      rr.ln.se = sqrt((risk.se_1/risk_1)^2 + (risk.se_0/risk_0)^2),
      rr.ll = exp(log(rr) + qnorm(0.025)*rr.ln.se),
      rr.ul = exp(log(rr) + qnorm(0.975)*rr.ln.se),
      
      # risk difference, standard error and confidence limits, using delta method
      rd = risk_1 - risk_0,
      rd.se = sqrt( (risk.se_0^2) + (risk.se_1^2) ),
      rd.ll = rd + qnorm(0.025)*rd.se,
      rd.ul = rd + qnorm(0.975)*rd.se,
      
      # cumulative incidence rate difference
      #cmlird = cml.rate_1 - cml.rate_0
    )
}

contrasts_km_rounded_cuts <- kmcontrasts(data_surv_rounded, c(0,postbaselinecuts))
write_rds(contrasts_km_rounded_cuts, fs::path(outdir, "contrasts_km_cuts_rounded.rds"), compress = "gz")

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# cox models ----

coxcontrast <- function(data, cuts=NULL){
  
  if (is.null(cuts)) {stop("Specify cuts.")}
  
  data <- data %>% 
    # create variable for cuts[1] for tstart in tmerge
    mutate(time0 = cuts[1])
  
  fup_split <-
    data %>%
    select(patient_id, new_id, treated) %>%
    uncount(weights = length(cuts)-1, .id="period_id") %>%
    mutate(
      fup_time = cuts[period_id],
      fup_period = paste0(cuts[period_id], "-", cuts[period_id+1]-1)
    ) %>%
    droplevels() %>%
    select(
      patient_id, new_id, period_id, fup_time, fup_period
    )
  
  data_split <-
    tmerge(
      data1 = data,
      data2 = data,
      id = new_id,
      tstart = time0,
      tstop = tte_outcome,
      ind_outcome = event(if_else(ind_outcome, tte_outcome, NA_real_))
    ) %>%
    # add post-treatment periods
    tmerge(
      data1 = .,
      data2 = fup_split,
      id = new_id,
      period_id = tdc(fup_time, period_id)
    ) %>%
    mutate(
      period_start = cuts[period_id],
      period_end = cuts[period_id+1],
    )
  
  
  if(length(cuts)>2){
    treatment_term <- "treated:strata(period_id)"
  } else if(length(cuts==2)){
    treatment_term <- "treated"
  } else
    stop("cuts must be >1")

  adjustment_formula <- as.formula(
    eval(
      paste(
        "Surv(tstart, tstop, ind_outcome) ~", treatment_term, "+",
        paste0(adjustment_variables_sequential, collapse=" + ")
      )
    )
  )
    
  data_cox <-
    data_split %>%
    group_by(!!subgroup_sym) %>%
    nest() %>%
    mutate(
      cox_obj = map(data, ~{
        coxph(
          adjustment_formula, 
          data = .x, 
          y=FALSE, 
          # Some individuals are included twice: as a control prior to vaccination then treated after
          # although follow-up time for such individuals doesn't overlap on the calendar time-scale,
          # the model uses time "time since trial_date" time scale, 
          # therefore it is possible for follow-up time to overlap.
          # Therefore: cluster the observations on patient_id to calculate robust variance:
          robust=TRUE, 
          id=patient_id, 
          na.action="na.fail"
        )
      }),
      cox_obj_tidy = map(cox_obj, ~broom::tidy(.x)),
    ) %>%
    select(!!subgroup_sym, cox_obj_tidy) %>%
    unnest(cox_obj_tidy) %>%
    # select only treatment terms (not interested in confounder effects)
    filter(str_detect(term, "^treated")) %>%
    mutate(
      # re-define period id as this doesn't fall out nicely from `broom::tidy`
      # it does fall out nicely from `broom.helpers::tidy_plus_plus`, but it's not compatible with the way the formula is specified due to scoping issues
      period_id = if(length(cuts)>2) {as.integer(str_match(term, "period_id=(\\d+)$")[,2])} else {1L}
    ) %>%
    transmute(
       !!subgroup_sym,
       period_id,
       period_start = cuts[period_id],
       period_end = cuts[period_id+1],
       fup_period = paste0(cuts[period_id], "-", cuts[period_id+1]),
       coxhazr = exp(estimate),
       coxhr.se = robust.se,
       coxhr.ll = exp(estimate + qnorm(0.025)*robust.se),
       coxhr.ul = exp(estimate + qnorm(0.975)*robust.se),
    )
  data_cox
  
}

# no rounding necessary as HRs are a safe statistic
contrasts_cox_cuts <- coxcontrast(data_matched, c(0,postbaselinecuts))
write_rds(contrasts_cox_cuts, fs::path(outdir, "contrasts_cox_cuts.rds"), compress = "gz")
