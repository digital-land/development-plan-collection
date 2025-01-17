.PHONY: \
	transformed\
	dataset\
	commit-dataset

# data sources
ifeq ($(PIPELINE_CONFIG_URL),)
PIPELINE_CONFIG_URL=$(CONFIG_URL)pipeline/$(COLLECTION_NAME)/
endif

ifeq ($(COLLECTION_DIR),)
COLLECTION_DIR=collection/
endif

ifeq ($(PIPELINE_DIR),)
PIPELINE_DIR=pipeline/
endif

# collected resources
ifeq ($(RESOURCE_DIR),)
RESOURCE_DIR=$(COLLECTION_DIR)resource/
endif

ifeq ($(RESOURCE_FILES),)
RESOURCE_FILES:=$(wildcard $(RESOURCE_DIR)*)
endif

ifeq ($(FIXED_DIR),)
FIXED_DIR=fixed/
endif

ifeq ($(CACHE_DIR),)
CACHE_DIR=var/cache/
endif

ifeq ($(TRANSFORMED_DIR),)
TRANSFORMED_DIR=transformed/
endif

ifeq ($(ISSUE_DIR),)
ISSUE_DIR=issue/
endif

ifeq ($(COLUMN_FIELD_DIR),)
COLUMN_FIELD_DIR=var/column-field/
endif

ifeq ($(DATASET_RESOURCE_DIR),)
DATASET_RESOURCE_DIR=var/dataset-resource/
endif

ifeq ($(DATASET_DIR),)
DATASET_DIR=dataset/
endif

ifeq ($(FLATTENED_DIR),)
FLATTENED_DIR=flattened/
endif

ifeq ($(DATASET_DIRS),)
DATASET_DIRS=\
	$(TRANSFORMED_DIR)\
	$(COLUMN_FIELD_DIR)\
	$(DATASET_RESOURCE_DIR)\
	$(ISSUE_DIR)\
	$(DATASET_DIR)\
	$(FLATTENED_DIR)
endif

ifeq ($(EXPECTATION_DIR),)
EXPECTATION_DIR = expectations/
endif

ifeq ($(PIPELINE_CONFIG_FILES),)
PIPELINE_CONFIG_FILES=\
	$(PIPELINE_DIR)column.csv\
	$(PIPELINE_DIR)combine.csv\
	$(PIPELINE_DIR)concat.csv\
	$(PIPELINE_DIR)convert.csv\
	$(PIPELINE_DIR)default.csv\
	$(PIPELINE_DIR)default-value.csv\
	$(PIPELINE_DIR)filter.csv\
	$(PIPELINE_DIR)lookup.csv\
	$(PIPELINE_DIR)old-entity.csv\
	$(PIPELINE_DIR)patch.csv\
	$(PIPELINE_DIR)skip.csv\
	$(PIPELINE_DIR)transform.csv
endif

define run-pipeline
	mkdir -p $(@D) $(ISSUE_DIR)$(notdir $(@D)) $(COLUMN_FIELD_DIR)$(notdir $(@D)) $(DATASET_RESOURCE_DIR)$(notdir $(@D))
	digital-land ${DIGITAL_LAND_OPTS} --dataset $(notdir $(@D)) $(DIGITAL_LAND_FLAGS) pipeline $(1) --issue-dir $(ISSUE_DIR)$(notdir $(@D)) --column-field-dir $(COLUMN_FIELD_DIR)$(notdir $(@D)) --dataset-resource-dir $(DATASET_RESOURCE_DIR)$(notdir $(@D)) $(PIPELINE_FLAGS) $< $@
endef

define build-dataset =
	mkdir -p $(@D)
	time digital-land ${DIGITAL_LAND_OPTS} --dataset $(notdir $(basename $@)) dataset-create --output-path $(basename $@).sqlite3 $(^)
	time datasette inspect $(basename $@).sqlite3 --inspect-file=$(basename $@).sqlite3.json
	time digital-land ${DIGITAL_LAND_OPTS} --dataset $(notdir $(basename $@)) dataset-entries $(basename $@).sqlite3 $@
	mkdir -p $(FLATTENED_DIR)
	time digital-land ${DIGITAL_LAND_OPTS} --dataset $(notdir $(basename $@)) dataset-entries-flattened $@ $(FLATTENED_DIR)
	md5sum $@ $(basename $@).sqlite3
	csvstack $(ISSUE_DIR)$(notdir $(basename $@))/*.csv > $(basename $@)-issue.csv
	mkdir -p $(EXPECTATION_DIR)
	time digital-land ${DIGITAL_LAND_OPTS} expectations-dataset-checkpoint --output-dir=$(EXPECTATION_DIR) --specification-dir=specification --data-path=$(basename $@).sqlite3
	csvstack $(EXPECTATION_DIR)/**/$(notdir $(basename $@))-results.csv > $(basename $@)-expectation-result.csv
	csvstack $(EXPECTATION_DIR)/**/$(notdir $(basename $@))-issues.csv > $(basename $@)-expectation-issue.csv
endef

collection::
	digital-land ${DIGITAL_LAND_OPTS} collection-pipeline-makerules > collection/pipeline.mk

-include collection/pipeline.mk

# restart the make process to pick-up collected resource files
second-pass::
	@$(MAKE) --no-print-directory transformed dataset

GDAL := $(shell command -v ogr2ogr 2> /dev/null)
UNAME := $(shell uname)

init::
	pip install csvkit
ifndef GDAL
ifeq ($(UNAME),Darwin)
	$(error GDAL tools not found in PATH)
endif
	sudo add-apt-repository ppa:ubuntugis/ppa
	sudo apt-get update
	sudo apt-get install gdal-bin
endif
	pyproj sync --file uk_os_OSTN15_NTv2_OSGBtoETRS.tif -v
ifeq ($(UNAME),Linux)
	dpkg-query -W libsqlite3-mod-spatialite >/dev/null 2>&1 || sudo apt-get install libsqlite3-mod-spatialite
endif

clobber::
	rm -rf $(DATASET_DIRS)

clean::
	rm -rf ./var

# local copy of the organisation dataset
init::	$(CACHE_DIR)organisation.csv

makerules::
	curl -qfsL '$(SOURCE_URL)/makerules/main/pipeline.mk' > makerules/pipeline.mk

save-transformed::
	aws s3 sync $(TRANSFORMED_DIR) s3://$(COLLECTION_DATASET_BUCKET_NAME)/$(REPOSITORY)/$(TRANSFORMED_DIR) --no-progress
	aws s3 sync $(ISSUE_DIR) s3://$(COLLECTION_DATASET_BUCKET_NAME)/$(REPOSITORY)/$(ISSUE_DIR) --no-progress
	aws s3 sync $(COLUMN_FIELD_DIR) s3://$(COLLECTION_DATASET_BUCKET_NAME)/$(REPOSITORY)/$(COLUMN_FIELD_DIR) --no-progress
	aws s3 sync $(DATASET_RESOURCE_DIR) s3://$(COLLECTION_DATASET_BUCKET_NAME)/$(REPOSITORY)/$(DATASET_RESOURCE_DIR) --no-progress

save-dataset::
	aws s3 sync $(DATASET_DIR) s3://$(COLLECTION_DATASET_BUCKET_NAME)/$(REPOSITORY)/$(DATASET_DIR) --no-progress
	@mkdir -p $(FLATTENED_DIR)
ifeq ($(HOISTED_COLLECTION_DATASET_BUCKET_NAME),digital-land-$(ENVIRONMENT)-collection-dataset-hoisted)
	aws s3 sync $(FLATTENED_DIR) s3://$(HOISTED_COLLECTION_DATASET_BUCKET_NAME)/data/ --no-progress
else
	aws s3 sync $(FLATTENED_DIR) s3://$(HOISTED_COLLECTION_DATASET_BUCKET_NAME)/dataset/ --no-progress
endif

save-expectations::
	@mkdir -p $(EXPECTATION_DIR)
	aws s3 sync $(EXPECTATION_DIR) s3://$(COLLECTION_DATASET_BUCKET_NAME)/$(EXPECTATION_DIR) --exclude "*" --include "*.csv" --no-progress

# convert an individual resource
# .. this assumes conversion is the same for every dataset, but it may not be soon
var/converted/%.csv: collection/resource/%
	mkdir -p var/converted/
	digital-land ${DIGITAL_LAND_OPTS} convert $<

transformed::
	@mkdir -p $(TRANSFORMED_DIR)

metadata.json:
	echo "{}" > $@

datasette:	metadata.json
	datasette serve $(DATASET_DIR)/*.sqlite3 \
	--setting sql_time_limit_ms 5000 \
	--load-extension $(SPATIALITE_EXTENSION) \
	--metadata metadata.json

FALLBACK_CONFIG_URL := https://files.planning.data.gov.uk/config/pipeline/$(COLLECTION_NAME)/

$(PIPELINE_DIR)%.csv:
	@mkdir -p $(PIPELINE_DIR)
	@if [ ! -f $@ ]; then \
		echo "Config file $@ not found locally. Attempting to download..."; \
		curl -qfsL '$(PIPELINE_CONFIG_URL)$(notdir $@)' -o $@ || \
		(echo "File not found in config repo. Attempting to download from AWS..." && curl -qfsL '$(FALLBACK_CONFIG_URL)$(notdir $@)' -o $@); \
	fi

config:: $(PIPELINE_CONFIG_FILES)

clean::
	rm -f $(PIPELINE_CONFIG_FILES)
