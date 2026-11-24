PATH := ~/.solc-select/artifacts/:~/.solc-select/artifacts/solc-0.8.21:~/.solc-select/artifacts/solc-0.5.12:$(PATH)
certora-srusds :; PATH=${PATH} certoraRun certora/SrUsds.conf$(if $(rule), --rule $(rule),)$(if $(results), --wait_for_results all,)
certora-queues :; PATH=${PATH} certoraRun certora/SrUsdsQueues.conf$(if $(rule), --rule $(rule),)$(if $(results), --wait_for_results all,)
