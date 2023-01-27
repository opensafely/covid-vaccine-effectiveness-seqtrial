# covid-vaccine-effectiveness-seqtrial

[View on OpenSAFELY](https://jobs.opensafely.org/repo/https%253A%252F%252Fgithub.com%252Fopensafely%252Fcovid-vaccine-effectiveness-seqtrial)

Details of the purpose and any published outputs from this project can be found at the link above.

The contents of this repository MUST NOT be considered an accurate or valid representation of the study or its purpose. 
This repository may reflect an incomplete or incorrect analysis with no further ongoing work.
The content has ONLY been made public to support the OpenSAFELY [open science and transparency principles](https://www.opensafely.org/about/#contributing-to-best-practice-around-open-science) and to support the sharing of re-usable code for other subsequent users.
No clinical, policy or safety conclusions must be drawn from the contents of this repository.

# About the OpenSAFELY framework

The OpenSAFELY framework is a Trusted Research Environment (TRE) for electronic
health records research in the NHS, with a focus on public accountability and
research quality.

Read more at [OpenSAFELY.org](https://opensafely.org).

# Licences
As standard, research projects have a MIT license. 

# Study details

🚨 This repo is archived, the code for this project has moved to [covid-vaccine-effectiveness-sequential-vs-single](https://github.com/opensafely/covid-vaccine-effectiveness-sequential-vs-single) 🚨

## project.yaml
The [`project.yaml`](./project.yaml) defines run-order and dependencies for all the analysis scripts. 
It is split into a series of "actions", each one implementing a step in the analysis pipeline.
The file is annotated to describe the purpose of each action. 
This file is where you should start if you wish to understand the analysis pipeline.

**The [`project.yaml`](./project.yaml) should *not* be edited directly**. To make changes, edit and run the [`create-project.R`](./create-project.R) script instead.
There is no need to run [`create_project.R`](./create_project.R) if you are simply cloning this repo.

