# Single trial vs sequential trial approaches for estimating COVID-19 vaccine effectiveness 

🚨 This repo is archived, the code for this project has moved to [covid-vaccine-effectiveness-sequential-vs-single](https://github.com/opensafely/covid-vaccine-effectiveness-sequential-vs-single) 🚨

You can run this project via [Gitpod](https://gitpod.io) in a web browser by clicking on this badge: [![Gitpod ready-to-code](https://img.shields.io/badge/Gitpod-ready--to--code-908a85?logo=gitpod)](https://gitpod.io/#https://github.com/opensafely/covid-vaccine-effectiveness-seqtrial)

<!--* The paper is [here]()--->
* If you are interested in how we defined our code lists, look in the [codelists folder](./codelists/).
* Developers and epidemiologists interested in the framework should review [the OpenSAFELY documentation](https://docs.opensafely.org)

## project.yaml
The [`project.yaml`](./project.yaml) defines run-order and dependencies for all the analysis scripts. 
It is split into a series of "actions", each one implementing a step in the analysis pipeline.
The file is annotated to describe the purpose of each action. 
This file is where you should start if you wish to understand the analysis pipeline.

**The [`project.yaml`](./project.yaml) should *not* be edited directly**. To make changes, edit and run the [`create-project.R`](./create-project.R) script instead.
There is no need to run [`create_project.R`](./create_project.R) if you are simply cloning this repo.

# About the OpenSAFELY framework

The OpenSAFELY framework is a Trusted Research Environment (TRE) for electronic
health records research in the NHS, with a focus on public accountability and
research quality.

Read more at [OpenSAFELY.org](https://opensafely.org).

# Licences
As standard, research projects have a MIT license. 
