// Copyright 2024 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#include <print.h>
#include <stdio.h>
#include <xs1.h>
#include <platform.h>
#include <assert.h>
#include <math.h>

#include "adc_pot.h"
#include "app_main.h"

on tile[0]: port p_adc[] = ADC_PINS;


typedef enum adc_state_t{
        ADC_IDLE = 2,
        ADC_CHARGING = 1,
        ADC_CONVERTING = 0 // Optimisation as ISA can do != 0 on select guard
}adc_state_t;


static inline uint16_t post_process_result( uint16_t raw_result,
                                            uint16_t *conversion_history,
                                            uint16_t *hysteris_tracker,
                                            unsigned adc_idx){
    // const int max_result_scale = (1 << ADC_BITS_TARGET) - 1;

    // Apply filter. First populate filter history.
    static unsigned filter_write_idx = 0;
    static unsigned filter_stable = 0;
    unsigned offset = adc_idx * RESULT_HISTORY_DEPTH + filter_write_idx;
    *(conversion_history + offset) = raw_result;
    if(adc_idx == ADC_NUM_CHANNELS - 1){
        if(++filter_write_idx == RESULT_HISTORY_DEPTH){
            filter_write_idx = 0;
            filter_stable = 1;
        }
    }
    // Apply moving average filter
    uint32_t accum = 0;
    uint16_t *hist_ptr = conversion_history + adc_idx * RESULT_HISTORY_DEPTH;
    for(int i = 0; i < RESULT_HISTORY_DEPTH; i++){
        accum += *hist_ptr;
        hist_ptr++;
    }
    uint16_t filtered_result = (accum / RESULT_HISTORY_DEPTH);

    // return filtered_result;

    // Apply hysteresis
    if(filtered_result > hysteris_tracker[adc_idx] + RESULT_HYSTERESIS || filtered_result == NUM_CAL){
        hysteris_tracker[adc_idx] = filtered_result;
    }
    if(filtered_result < hysteris_tracker[adc_idx] - RESULT_HYSTERESIS || filtered_result == 0){
        hysteris_tracker[adc_idx] = filtered_result;
    }

    uint16_t filtered_hysteris_result = hysteris_tracker[adc_idx];

    return filtered_hysteris_result;
}


unsigned gen_lookup(uint16_t up[], uint16_t down[], unsigned num_points,
                    float r_ohms, float capacitor_f, float rs_ohms,
                    float v_rail, float v_thresh){
    printstrln("gen_lookup");
    unsigned max_ticks = 0;
    //TODO rs_ohms
    printf("r_ohms: %f capacitor_f: %f v_rail: %f v_thresh: %f\n", r_ohms, capacitor_f * 1e12, v_rail, v_thresh);
    const float phi = 2e-38;
    for(unsigned i = 0; i < num_points + 1; i++){
        // Calculate equivalent resistance of pot
        float r_low = r_ohms * (i + phi) / num_points;  
        float r_high = r_ohms * ((num_points - i) + phi) / num_points;  
        float r_parallel = 1 / (1 / r_low + 1 / r_high); // When reading the equivalent resistance of pot is this

        // Calculate equivalent resistances when charging via Rs
        float rp_low = 1 / (1 / r_high + 1 / rs_ohms);
        float rp_high = 1 / (1 / r_low + 1 / rs_ohms);

        // Calculate actual charge voltage of capacitor
        float v_charge_h = r_low / (r_low + rp_high) * v_rail;
        float v_charge_l = rp_low / (rp_low + r_high) * v_rail;

        // Calculate time to for cap to reach threshold from charge volatage
        float v_pot = (float)i / num_points * v_rail;
        float t_down = (-r_parallel) * capacitor_f * log(1 - (v_charge_h - v_thresh) / (v_rail - v_pot));  
        float t_up = (-r_parallel) * capacitor_f * log(1 - ((v_thresh - v_charge_l) / v_pot));

        // Convert to 100MHz timer ticks
        unsigned t_down_ticks = (unsigned)(t_down * XS1_TIMER_HZ);
        unsigned t_up_ticks = (unsigned)(t_up * XS1_TIMER_HZ);

        printf("i: %u r_parallel: %f t_down: %u t_up: %u\n", i, r_parallel, t_down_ticks, t_up_ticks);

        up[i] = t_up_ticks;
        down[i] = t_down_ticks;
        max_ticks = up[i] > max_ticks ? up[i] : max_ticks;
        max_ticks = down[i] > max_ticks ? down[i] : max_ticks;

        assert(max_ticks < 65536); // We have a 16b port timer, so if max is more than this, then we need to slow clock or lower RC
    }

    return max_ticks;
}

static inline unsigned lookup(int is_up, uint16_t ticks, uint16_t up[], uint16_t down[], unsigned num_points, unsigned port_time_offset){
    unsigned max_arg = 0;

    if(ticks > port_time_offset){
        ticks -= port_time_offset;
    } else{
        ticks = 0;
    }

    if(is_up){
        uint16_t max = 0;
        max_arg = num_points;
        for(int i = num_points; i >= 0; i--){
            if(ticks > up[i]){
                if(up[i] > max){
                    max_arg = i - 1;
                    max = up[i];
                } 
            }
        }
    } else {
        int16_t max = 0;
        for(int i = 0; i < num_points + 1; i++){
            if(ticks > down[i]){
                if(down[i] > max){
                    max_arg = i;
                    max = up[i];
                }
            }
        }
    }

    return max_arg;
}


void cal_threshold(port p_adc){
    int hist[RESULT_HISTORY_DEPTH] = {0};
    int idx = 0;
    while(1){
        int tmp;
        p_adc :> tmp;
        hist[idx] = tmp * 100;
        if(++idx == RESULT_HISTORY_DEPTH){
            idx = 0;
        }
        int accum = 0;
        for(int i=0; i< RESULT_HISTORY_DEPTH; i++){
            accum += hist[i];
        } 
        accum /= RESULT_HISTORY_DEPTH;
        printintln(accum);
        delay_milliseconds(10);
    }
}

void adc_pot_task(chanend c_adc){
    printstrln("adc_pot_task");
  
    // Current conversion index
    unsigned adc_idx = 0;
    uint16_t results[ADC_NUM_CHANNELS] = {0}; // The ADC read values

    timer tmr_charge;
    timer tmr_discharge;
    timer tmr_overshoot;

    // Set all ports to input and set drive strength
    const int port_drive = DRIVE_8MA;
    for(int i = 0; i < ADC_NUM_CHANNELS; i++){
        unsigned dummy;
        p_adc[i] :> dummy;
        set_pad_properties(p_adc[i], port_drive, PULL_NONE, 0, 0);

    }


    const int capacitor_pf = 4000;
    const int resistor_ohms = 47000; // nominal maximum value ned to end
    const int resistor_tol_pc = 20; // TODO add
    const int resistor_series_ohms = 470;

    const float v_rail = 3.3;
    const float v_thresh = 1.18;
    const unsigned port_time_offset = 20; // How long approx minimum time to trigger port select

    const int rc_times_to_charge_fully = 10; // 5 RC times should be sufficient but double it for best accuracy
    const uint32_t max_charge_period_ticks = ((uint64_t)rc_times_to_charge_fully * capacitor_pf * resistor_ohms / 2) / 10000;

    const int num_time_constants_disch_max = 3;
    const uint32_t max_discharge_period_ticks = ((uint64_t)capacitor_pf * num_time_constants_disch_max * resistor_ohms / 2) / 10000;

    // assert(ADC_READ_INTERVAL > max_charge_period_ticks + max_discharge_period_ticks * 2); // Ensure conversion rate is low enough. *2 to allow post processing time
    // printintln(ADC_READ_INTERVAL); printintln(max_charge_period_ticks +max_discharge_period_ticks);


    // Generate calibration table
    uint16_t cal_up[NUM_CAL + 1] = {0};
    uint16_t cal_down[NUM_CAL + 1] = {0};
    uint16_t max_table_ticks = gen_lookup(cal_up, cal_down, NUM_CAL,
                                        (float)resistor_ohms, (float)capacitor_pf * 1e-12, (float)resistor_series_ohms,
                                        v_rail, v_thresh);
    unsigned overshoot_idx = (unsigned)(v_thresh / v_rail * NUM_CAL);
    printf("max_charge_period_ticks: %lu max_discharge_period_ticks: %lu max_table_ticks: %u\n", max_charge_period_ticks, max_discharge_period_ticks, max_table_ticks);


    // Post processing variables
    uint16_t conversion_history[ADC_NUM_CHANNELS][RESULT_HISTORY_DEPTH] = {{0}};
    uint16_t hysteris_tracker[ADC_NUM_CHANNELS] = {0};

 
    adc_state_t adc_state = ADC_IDLE;

    // Set init time for charge
    int time_trigger_charge = 0;
    tmr_charge :> time_trigger_charge;
    time_trigger_charge += max_charge_period_ticks; // start in one conversion period's
    
    int time_trigger_discharge = 0;
    int time_trigger_overshoot = 0;

    int16_t start_time, end_time;
    unsigned init_port_val = 0;

    printstrln("adc_task");
    while(1){
        select{
            case adc_state == ADC_IDLE => tmr_charge when timerafter(time_trigger_charge) :> int _:
                p_adc[adc_idx] :> init_port_val;
                time_trigger_discharge = time_trigger_charge + max_charge_period_ticks;

                p_adc[adc_idx] <: init_port_val ^ 0x1; // Drive opposite to what we read to "charge"
                adc_state = ADC_CHARGING;
            break;

            case adc_state == ADC_CHARGING => tmr_discharge when timerafter(time_trigger_discharge) :> int _:
                p_adc[adc_idx] :> int _ @ start_time; // Make Hi Z and grab time
                time_trigger_overshoot = time_trigger_discharge + max_discharge_period_ticks;

                adc_state = ADC_CONVERTING;
            break;

            case adc_state == ADC_CONVERTING => p_adc[adc_idx] when pinseq(init_port_val) :> int _ @ end_time:
                int32_t conversion_time = (end_time - start_time);
                if(conversion_time < 0){
                    conversion_time += 0x10000; // Account for port timer wrapping
                }
                int t0, t1;
                tmr_charge :> t0; 
                uint16_t result = lookup(init_port_val, conversion_time, cal_up, cal_down, NUM_CAL, port_time_offset);
                uint16_t post_proc_result = post_process_result(result, conversion_history[0], hysteris_tracker, adc_idx);
                results[adc_idx] = post_proc_result;
                tmr_charge :> t1; 
                printf("ticks: %u result: %u post_proc: %u ticks: %u is_up: %d proc_ticks: %d\n", conversion_time, result, post_proc_result, conversion_time, init_port_val, t1-t0);


                if(++adc_idx == ADC_NUM_CHANNELS){
                    adc_idx = 0;
                }
                time_trigger_charge += ADC_READ_INTERVAL;

                adc_state = ADC_IDLE;
            break;

            case adc_state == ADC_CONVERTING => tmr_overshoot when timerafter(time_trigger_overshoot) :> int _:
                p_adc[adc_idx] :> int _ @ end_time;
                printf("result: %u overshoot\n", overshoot_idx);
                if(++adc_idx == ADC_NUM_CHANNELS){
                    adc_idx = 0;
                }
                time_trigger_charge += ADC_READ_INTERVAL;

                adc_state = ADC_IDLE;
            break;
        }
    } // while 1
}