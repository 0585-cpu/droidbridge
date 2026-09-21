package io.droidbridge

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.lifecycle.viewmodel.compose.viewModel
import io.droidbridge.ui.RelayScreen
import io.droidbridge.ui.RelayViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface {
                    val vm: RelayViewModel = viewModel(factory = RelayViewModelFactory(applicationContext))
                    RelayScreen(vm)
                }
            }
        }
    }
}
