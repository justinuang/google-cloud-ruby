package com.example;

import com.example.sidecar.SidecarServiceImpl;
import io.grpc.Server;
import io.grpc.netty.shaded.io.grpc.netty.NettyServerBuilder;
import io.grpc.netty.shaded.io.netty.channel.EventLoopGroup;
import io.grpc.netty.shaded.io.netty.channel.epoll.EpollEventLoopGroup;
import io.grpc.netty.shaded.io.netty.channel.epoll.EpollServerDomainSocketChannel;
import io.grpc.netty.shaded.io.netty.channel.unix.DomainSocketAddress;

import java.io.IOException;

public class BigtableSidecar {
    public static void main(String[] args) throws IOException, InterruptedException {
        String socketPath = null;
        String readyFifo = null;
        String project = null;
        String instance = null;

        for (int i = 0; i < args.length; i++) {
            if ("--ready-fifo".equals(args[i]) && i + 1 < args.length) {
                readyFifo = args[i + 1];
                i++;
            } else if ("--project".equals(args[i]) && i + 1 < args.length) {
                project = args[i + 1];
                i++;
            } else if ("--instance".equals(args[i]) && i + 1 < args.length) {
                instance = args[i + 1];
                i++;
            } else if (socketPath == null) {
                socketPath = args[i];
            }
        }

        if (socketPath == null) {
            System.err.println("Usage: BigtableSidecar <socket_path> [--ready-fifo <fifo_path>] [--project <project>] [--instance <instance>]");
            System.exit(1);
        }

        System.err.println("Java Sidecar: Starting gRPC server on " + socketPath);
        System.err.println("Java Sidecar JRE Home: " + System.getProperty("java.home"));
        System.err.println("Java Sidecar JRE Version: " + System.getProperty("java.version"));
        System.err.println("Java Sidecar ENV [CBT_ENABLE_DIRECTPATH]: " + System.getenv("CBT_ENABLE_DIRECTPATH"));
        

        
        if (project != null && instance != null) {
            System.err.println("Java Sidecar: Proxying to Project: " + project + ", Instance: " + instance);
        }

        EventLoopGroup bossGroup = new EpollEventLoopGroup(1);
        EventLoopGroup workerGroup = new EpollEventLoopGroup();

        Server server = NettyServerBuilder.forAddress(new DomainSocketAddress(socketPath))
                .channelType(EpollServerDomainSocketChannel.class)
                .workerEventLoopGroup(workerGroup)
                .bossEventLoopGroup(bossGroup)
                .addService(new SidecarServiceImpl(project, instance))
                .build();

        server.start();

        System.err.println("Java Sidecar: Server started, listening on " + socketPath);

        if (readyFifo != null) {
            try (java.io.FileOutputStream fos = new java.io.FileOutputStream(readyFifo)) {
                fos.write(1);
                fos.flush();
                System.err.println("Java Sidecar: Signaled readiness to FIFO: " + readyFifo);
            } catch (java.io.IOException e) {
                System.err.println("Java Sidecar: Failed to signal readiness to FIFO: " + e.getMessage());
            }
        }


        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.err.println("Java Sidecar: Shutting down...");
            server.shutdown();
            System.err.println("Java Sidecar: Shut down complete.");
        }));

        server.awaitTermination();
    }
}

