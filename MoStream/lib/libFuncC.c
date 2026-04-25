/* ===------------------------------------------------------------------------=== *
 *  This program is free software; you can redistribute it and/or modify it
 *  under the terms of the GNU Lesser General Public License version 3 as
 *  published by the Free Software Foundation.
 *  
 *  This program is distributed in the hope that it will be useful, but WITHOUT
 *  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 *  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 *  License for more details.
 *  
 *  You should have received a copy of the GNU Lesser General Public License
 *  along with this program; if not, write to the Free Software Foundation,
 *  Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 * ===------------------------------------------------------------------------=== */

#include<pthread.h>
#include<sched.h>
#include<stdint.h>
#include<errno.h>

// Pins the current thread to the specified CPU core. Returns 0 on success, or a non-zero errno on failure
int pin_thread_to_cpu(int cpu)
{
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);

    int err = pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
    if (err != 0)
        return err; // non-zero errno on failure
    return 0;
}

// Pins the current thread to the specified CPU core. Returns 0 on success, or a negative errno on failure
int pin_thread_to_cpu_checked(int cpu)
{
    int r = pin_thread_to_cpu(cpu);
    if (r == 0)
        return 0;
    return -r;
}
